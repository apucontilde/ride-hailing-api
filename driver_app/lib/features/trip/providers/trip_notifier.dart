import 'dart:async';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/location/location_service.dart';
import '../../../core/ride/ride_state_notifier.dart';
import '../../rides/data/rides_repository.dart';
import '../model/ride_stop.dart';

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

/// One ordered waypoint the trip screen renders and routes toward: the pickup,
/// any intermediate stops, then the destination.
class TripWaypoint {
  final double lat;
  final double lng;
  final String address;
  final bool isPickup;
  final bool isDestination;

  const TripWaypoint({
    required this.lat,
    required this.lng,
    required this.address,
    this.isPickup = false,
    this.isDestination = false,
  });

  @override
  bool operator ==(Object other) =>
      other is TripWaypoint &&
      other.lat == lat &&
      other.lng == lng &&
      other.address == address &&
      other.isPickup == isPickup &&
      other.isDestination == isDestination;

  @override
  int get hashCode => Object.hash(lat, lng, address, isPickup, isDestination);
}

class TripState {
  final TripStage stage;
  final Ride? currentRide;
  final String? cancelledBy;
  final String? routeError;
  final RouteCache? route;

  /// The sibling `stops` itinerary from `GET /driver/rides/:id` (ordered by
  /// `sequence`, pickup excluded, destination last). Empty until loaded and for
  /// a pre-multi-stop ride.
  final List<RideStop> stops;

  const TripState({
    this.stage = TripStage.pre,
    this.currentRide,
    this.cancelledBy,
    this.routeError,
    this.route,
    this.stops = const [],
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
    bool clearRouteError = false,
    String? routeError,
    RouteCache? route,
    List<RideStop>? stops,
  }) {
    return TripState(
      stage: stage ?? this.stage,
      currentRide: clearRide ? null : currentRide ?? this.currentRide,
      cancelledBy: cancelledBy ?? this.cancelledBy,
      routeError: clearRouteError ? null : routeError ?? this.routeError,
      route: route ?? this.route,
      stops: stops ?? this.stops,
    );
  }
}

class TripNotifier extends StateNotifier<TripState> {
  /// How far the driver must travel from the origin the cached route was
  /// requested at before a fresh road route is worth fetching.
  static const double refetchThresholdM = 200;

  /// Default radius within which an intermediate stop counts as reached, so the
  /// next waypoint advances. Overridable in tests via
  /// [nextStopArrivalRadiusProvider].
  static const double defaultNextStopArrivalRadiusM = 120;

  final Ref _ref;

  /// Keyed by destination (`toLat,toLng`): the origin is the driver's own
  /// moving position, so keying on it too would never hit and would grow the
  /// map on every GPS fix.
  final Map<String, RouteCache> _routeCache = {};
  bool _routeInFlight = false;

  /// The ride id whose `stops` have been loaded (or attempted), so the sibling
  /// itinerary is fetched once per journey.
  String? _loadedStopsForRideId;
  bool _stopsInFlight = false;

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
    // A different ride is a different journey: the cached route and the
    // itinerary belonged to the previous trip.
    final rideChanged = state.currentRide?.id != ride.id;
    if (rideChanged) {
      _routeCache.clear();
      _loadedStopsForRideId = null;
    }
    final stage = _stageFromStatus(ride.status);
    state = state.copyWith(
      stage: stage,
      currentRide: ride,
      cancelledBy: ride.cancelledBy,
      // Drop the previous trip's itinerary immediately; `_ensureStopsLoaded`
      // repopulates it for the new ride.
      stops: rideChanged ? const [] : null,
    );
    _ensureStopsLoaded(ride);
  }

  /// Loads the sibling `stops` once per ride id. Non-fatal: a failure leaves
  /// [TripState.stops] empty and the map/drawer still degrade to the ride's own
  /// pickup/dropoff.
  Future<void> _ensureStopsLoaded(Ride ride) async {
    if (ride.id.isEmpty) return;
    if (_loadedStopsForRideId == ride.id || _stopsInFlight) return;
    _stopsInFlight = true;
    try {
      final itinerary =
          await _ref.read(ridesRepositoryProvider).fetchRideItinerary(ride.id);
      // The ride may have changed while the request was in flight.
      if (state.currentRide?.id != ride.id) return;
      _loadedStopsForRideId = ride.id;
      state = state.copyWith(stops: itinerary.stops);
    } catch (_) {
      // Non-fatal: the map still draws pickup/dropoff from the held ride.
      _loadedStopsForRideId = ride.id;
    } finally {
      _stopsInFlight = false;
    }
  }

  /// The ordered waypoints of the trip: pickup, the intermediate stops, then the
  /// destination. The destination always comes from the held ride's own
  /// `dropoff_*`, so a destination-only `ride.updated` moves it without a stop
  /// refetch.
  List<TripWaypoint> waypointsFor(Ride ride) {
    final points = <TripWaypoint>[];
    final pickupLat = ride.pickupLat;
    final pickupLng = ride.pickupLng;
    if (pickupLat != null && pickupLng != null) {
      points.add(TripWaypoint(
        lat: pickupLat,
        lng: pickupLng,
        address: ride.pickupAddress ?? 'Pickup',
        isPickup: true,
      ));
    }
    for (final stop in state.stops) {
      // The destination row is replaced by the live dropoff below.
      if (stop.isDestination) continue;
      points.add(TripWaypoint(
        lat: stop.lat,
        lng: stop.lng,
        address: stop.address.isEmpty ? 'Stop' : stop.address,
      ));
    }
    final dropoffLat = ride.dropoffLat;
    final dropoffLng = ride.dropoffLng;
    if (dropoffLat != null && dropoffLng != null) {
      points.add(TripWaypoint(
        lat: dropoffLat,
        lng: dropoffLng,
        address: ride.dropoffAddress ?? 'Destination',
        isDestination: true,
      ));
    }
    return points;
  }

  /// The immediate next waypoint the driver is heading toward at [stage], or
  /// `null` when the trip is over. On `driving`, the first waypoint farther than
  /// [nextStopArrivalRadiusProvider] from the last fix, with the destination
  /// always last. The server exposes no per-stop completion signal, so this is a
  /// documented local heuristic.
  TripWaypoint? nextWaypoint(TripStage stage, Ride ride) {
    switch (stage) {
      case TripStage.pre:
      case TripStage.enrouteToPickup:
      case TripStage.arrived:
        final lat = ride.pickupLat;
        final lng = ride.pickupLng;
        if (lat == null || lng == null) return null;
        return TripWaypoint(
          lat: lat,
          lng: lng,
          address: ride.pickupAddress ?? 'Pickup',
          isPickup: true,
        );
      case TripStage.driving:
        final points =
            waypointsFor(ride).where((point) => !point.isPickup).toList();
        if (points.isEmpty) return null;
        final position = _ref.read(lastPositionProvider);
        if (position == null) return points.first;
        final radius = _ref.read(nextStopArrivalRadiusProvider);
        for (final point in points) {
          if (_distanceM(position.lat, position.lng, point.lat, point.lng) >
              radius) {
            return point;
          }
        }
        return points.last;
      case TripStage.post:
      case TripStage.cancelled:
        return null;
    }
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
      // Arrival is server-owned (`api_plans/[arrival]_proximity_arrival_geofence.md`):
      // the geofence advances accepted -> driver_arrived and broadcasts
      // `ride.updated`, so the driver never sends `driver_arrived` itself.
      TripStage.enrouteToPickup => null,
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
      state = state.copyWith(route: route, clearRouteError: true);
      return route;
    } catch (e) {
      state = state.copyWith(routeError: apiErrorMessage(e, 'Route unavailable'));
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

/// Radius within which an intermediate stop is considered reached, so the
/// "next waypoint" advances. Overridable in tests; the server has no per-stop
/// completion signal yet (`driver_app_plans/[ontrip]_itinerary_next_stop.md`).
final nextStopArrivalRadiusProvider =
    Provider<double>((ref) => TripNotifier.defaultNextStopArrivalRadiusM);
