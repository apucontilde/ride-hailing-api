import 'dart:async';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/ride/ride_state_notifier.dart';

/// Trip stages, one per server-enforced ride status
/// (`internal/service/ride.go` `validTransitions`):
/// `accepted → driver_arrived → in_progress → completed`, plus the terminal
/// `cancelled`. `accepted` and `driver_arrived` are deliberately *not* merged:
/// collapsing them made the first button press send `in_progress` from
/// `accepted`, which the server rejects with 400.
enum TripStage {
  /// `pending` — the offer has not been accepted, so there is no trip to drive.
  pre,
  /// `accepted` — driving to the pickup.
  enrouteToPickup,
  /// `driver_arrived` — at the pickup, waiting for the rider.
  arrived,
  /// `in_progress` — driving to the dropoff.
  driving,
  /// `completed`.
  post,
  /// `cancelled`.
  cancelled,
}

/// A fetched `GET /navigation/route` result, plus the origin it was requested
/// from so the next call can tell whether the driver has moved far enough to
/// justify a refetch.
class RouteCache {
  final List<Map<String, dynamic>> polyline;
  final double distance;
  final int duration;

  /// `true` when the backend had no road coverage and returned the straight
  /// haversine line instead (region-scoped routing, api_plans/05).
  final bool isEstimate;

  final double originLat;
  final double originLng;
  final double toLat;
  final double toLng;
  final DateTime fetchedAt;

  RouteCache({
    required this.polyline,
    required this.distance,
    required this.duration,
    required this.isEstimate,
    required this.originLat,
    required this.originLng,
    required this.toLat,
    required this.toLng,
    required this.fetchedAt,
  });
}

class TripState {
  final TripStage stage;
  final Ride? currentRide;
  final String? cancelledBy;
  final RouteCache? route;

  const TripState({
    this.stage = TripStage.pre,
    this.currentRide,
    this.cancelledBy,
    this.route,
  });

  /// The server only allows cancelling from `pending`, `accepted` and
  /// `driver_arrived`; once `in_progress` only the rider can cancel.
  bool get canCancel =>
      stage == TripStage.pre ||
      stage == TripStage.enrouteToPickup ||
      stage == TripStage.arrived;

  /// The trip is over: nothing to drive, the screen is a receipt or a
  /// cancellation notice.
  bool get isTerminal => stage == TripStage.post || stage == TripStage.cancelled;

  TripState copyWith({
    TripStage? stage,
    Ride? currentRide,
    bool clearRide = false,
    String? cancelledBy,
    RouteCache? route,
  }) {
    return TripState(
      stage: stage ?? this.stage,
      currentRide: clearRide ? null : currentRide ?? this.currentRide,
      cancelledBy: cancelledBy ?? this.cancelledBy,
      route: route ?? this.route,
    );
  }
}

class TripNotifier extends StateNotifier<TripState> {
  /// How far the driver must travel from the origin the cached route was
  /// requested at before a fresh road route is worth fetching.
  static const double refetchThresholdM = 200;

  final Ref _ref;

  /// Keyed by destination (`toLat,toLng`): the origin is the driver's own
  /// moving position, so keying on it too would never hit and would grow the
  /// map on every GPS fix.
  final Map<String, RouteCache> _routeCache = {};
  bool _routeInFlight = false;

  TripNotifier(this._ref) : super(const TripState()) {
    // Seed from the ride already held — `ref.listen` only fires on *later*
    // changes, so without this the screen would come up empty whenever it is
    // opened while a trip is running (home pushes `/trip` in exactly that
    // case, as does a launch restore from `GET /driver/rides/current`).
    final current = _ref.read(rideStateProvider);
    if (current.currentRide != null) _syncFromRideState(current);
    _ref.listen(rideStateProvider, (prev, next) {
      _syncFromRideState(next);
    });
  }

  TripStage _stageFromStatus(String status) => switch (status) {
        'pending' => TripStage.pre,
        'accepted' => TripStage.enrouteToPickup,
        'driver_arrived' => TripStage.arrived,
        'in_progress' => TripStage.driving,
        'completed' => TripStage.post,
        'cancelled' => TripStage.cancelled,
        _ => TripStage.pre,
      };

  void _syncFromRideState(RideState rideState) {
    final ride = rideState.currentRide;
    if (ride == null) {
      if (rideState.offeredRideId == null) {
        state = const TripState();
      }
      return;
    }
    // A different ride is a different journey: the cached route belonged to
    // the previous trip's destination.
    if (state.currentRide?.id != ride.id) {
      _routeCache.clear();
    }
    final stage = _stageFromStatus(ride.status);
    state = state.copyWith(
      stage: stage,
      currentRide: ride,
      cancelledBy: ride.cancelledBy,
    );
  }

  /// Advance the trip one step through the server-enforced state machine.
  ///
  /// The PUT response already carries the full updated ride, so it is applied
  /// optimistically; the `ride.updated` broadcast confirms the same thing and
  /// is merged on top.
  Future<void> advance() async {
    final ride = state.currentRide;
    if (ride == null || ride.id.isEmpty) return;
    final nextStatus = switch (state.stage) {
      TripStage.enrouteToPickup => 'driver_arrived',
      TripStage.arrived => 'in_progress',
      TripStage.driving => 'completed',
      // `pending` has no driver-side transition (the server allows
      // accepted|cancelled|no_driver_available), and the trip is over.
      TripStage.pre || TripStage.post || TripStage.cancelled => null,
    };
    if (nextStatus == null) return;
    try {
      final response = await _ref.read(apiClientProvider).dio.put(
        ApiEndpoints.driverRideStatus(ride.id),
        data: {'status': nextStatus},
      );
      _adoptServerRide(response.data);
    } catch (_) {
      // A rejected transition (400) or a dead socket: the server's own
      // `ride.updated` is the source of truth, so stay put and wait.
    }
  }

  /// Cancel the trip. Allowed only before `in_progress` — afterwards the
  /// rider can still cancel, but the driver cannot.
  ///
  /// [reason] is sent for forward compatibility only: the backend handler
  /// (`internal/handler/ride.go` `CancelRide`) binds no body and records
  /// `cancelled_by` from the caller's role.
  Future<void> cancelTrip({String? reason}) async {
    final ride = state.currentRide;
    if (ride == null || ride.id.isEmpty) return;
    if (!state.canCancel) return;
    try {
      final response = await _ref.read(apiClientProvider).dio.post(
        ApiEndpoints.driverRideCancel(ride.id),
        data: reason != null ? {'reason': reason} : null,
      );
      _adoptServerRide(response.data);
    } catch (_) {
      // Server confirms or rejects via ride.updated.
    }
  }

  /// Fetch the road-following route from the driver to [toLat]/[toLng].
  ///
  /// Repeat calls for the same destination within [refetchThresholdM] of the
  /// cached route's origin return that route without hitting the network, so
  /// the screen can call this on every position update. Returns `null` when
  /// the request fails (500 / no coverage) — the caller then draws the
  /// straight-line fallback.
  Future<RouteCache?> fetchRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    required double currentLat,
    required double currentLng,
  }) async {
    final key = '$toLat,$toLng';
    final cached = _routeCache[key];
    if (cached != null &&
        _distanceM(currentLat, currentLng, cached.originLat, cached.originLng) <
            refetchThresholdM) {
      return cached;
    }
    // Collapse concurrent callers (position stream + stage change) onto the
    // request already in flight.
    if (_routeInFlight) return cached;
    _routeInFlight = true;
    try {
      final response = await _ref.read(apiClientProvider).dio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: {
              'from_lat': fromLat,
              'from_lng': fromLng,
              'to_lat': toLat,
              'to_lng': toLng,
            },
          );
      final data = response.data as Map<String, dynamic>;
      final polyline = (data['polyline'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((p) => {
                'lat': _asDouble(p['lat']),
                'lng': _asDouble(p['lng']),
              })
          .toList();
      final route = RouteCache(
        polyline: polyline,
        distance: _asDouble(data['total_distance_m']),
        duration: (data['total_duration_s'] as num?)?.toInt() ?? 0,
        isEstimate: data['is_estimate'] == true,
        originLat: fromLat,
        originLng: fromLng,
        toLat: toLat,
        toLng: toLng,
        fetchedAt: DateTime.now(),
      );
      _routeCache[key] = route;
      state = state.copyWith(route: route);
      return route;
    } catch (_) {
      return null;
    } finally {
      _routeInFlight = false;
    }
  }

  /// Drops the trip state and the route cache, so the next ride starts clean.
  void reset() {
    _routeCache.clear();
    state = const TripState();
  }

  /// Hands a ride the server just returned to the websocket-backed store, so
  /// `/home` and the trip screen agree on the held ride even when the socket
  /// never delivered the matching broadcast.
  void _adoptServerRide(dynamic responseData) {
    if (responseData is! Map<String, dynamic>) return;
    final rideJson = responseData['ride'];
    if (rideJson is! Map<String, dynamic>) return;
    _ref.read(rideStateProvider.notifier).adoptRide(Ride.fromJson(rideJson));
  }

  static double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  /// Great-circle distance in meters (haversine).
  static double _distanceM(double lat1, double lng1, double lat2, double lng2) {
    const earthRadiusM = 6371000.0;
    const degToRad = 0.017453292519943295;
    final dLat = (lat2 - lat1) * degToRad;
    final dLng = (lng2 - lng1) * degToRad;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * degToRad) *
            cos(lat2 * degToRad) *
            sin(dLng / 2) *
            sin(dLng / 2);
    return 2 * earthRadiusM * asin(sqrt(a.clamp(0.0, 1.0)));
  }
}

final tripNotifierProvider = StateNotifierProvider<TripNotifier, TripState>((ref) {
  return TripNotifier(ref);
});
