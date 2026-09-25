import 'dart:async';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/ride/ride_state_notifier.dart';

/// Trip stages derived from the server-enforced ride status.
enum TripStage { pre, enrouteToPickup, driving, post, cancelled }

/// Route cache entry.
class RouteCache {
  final List<Map<String, dynamic>> polyline;
  final double distance;
  final int duration;
  final DateTime fetchedAt;

  RouteCache({
    required this.polyline,
    required this.distance,
    required this.duration,
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
  final Ref _ref;
  final Map<String, RouteCache> _routeCache = {};

  TripNotifier(this._ref) : super(const TripState()) {
    // Observe ride state changes to update stage.
    _ref.read(rideStateProvider);
    _observeRideState();
  }

  void _observeRideState() {
    _ref.listen(rideStateProvider, (prev, next) {
      _syncFromRideState(next);
    });
  }

  TripStage _stageFromStatus(String status) => switch (status) {
        'pending' => TripStage.pre,
        'accepted' => TripStage.enrouteToPickup,
        'driver_arrived' => TripStage.enrouteToPickup,
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
    final stage = _stageFromStatus(ride.status);
    String? cancelledBy = ride.cancelledBy;
    state = state.copyWith(
      stage: stage,
      currentRide: ride,
      cancelledBy: cancelledBy,
    );
  }

  /// Advance the trip through the server-enforced state machine.
  Future<void> advance() async {
    final ride = state.currentRide;
    if (ride == null) return;
    String nextStatus;
    switch (state.stage) {
      case TripStage.pre:
        nextStatus = 'driver_arrived';
      case TripStage.enrouteToPickup:
        nextStatus = 'in_progress';
      case TripStage.driving:
        nextStatus = 'completed';
      case TripStage.post:
      case TripStage.cancelled:
        return;
    }
    try {
      await _ref.read(apiClientProvider).dio.put(
        ApiEndpoints.driverRideStatus(ride.id),
        data: {'status': nextStatus},
      );
    } catch (_) {
      // Server confirms via ride.updated; ignore network errors.
    }
  }

  /// Cancel the trip (allowed only pre-in_progress).
  Future<void> cancelTrip({String? reason}) async {
    final ride = state.currentRide;
    if (ride == null) return;
    if (state.stage == TripStage.driving || state.stage == TripStage.post || state.stage == TripStage.cancelled) {
      return; // Cannot cancel after in_progress.
    }
    try {
      await _ref.read(apiClientProvider).dio.post(
        ApiEndpoints.driverRideCancel(ride.id),
        data: reason != null ? {'reason': reason} : null,
      );
    } catch (_) {
      // Server confirms via ride.updated; ignore network errors.
    }
  }

  /// Fetch navigation route between two points, with 200 m refetch threshold.
  Future<RouteCache?> fetchRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
    required double currentLat,
    required double currentLng,
  }) async {
    final key = '$fromLat,$fromLng:$toLat,$toLng';
    final cached = _routeCache[key];
    if (cached != null) {
      final distanceFromCache = _approxDistance(
        currentLat,
        currentLng,
        fromLat,
        fromLng,
      );
      if (distanceFromCache < 200) {
        return cached;
      }
    }
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
      final polylineData = data['polyline'] as List<dynamic>? ?? [];
      final polyline = polylineData.map((p) => {
        'lat': (p['lat'] ?? 0.0) as double,
        'lng': (p['lng'] ?? 0.0) as double,
      }).toList();
      final distance = (data['total_distance_m'] as num?)?.toDouble() ?? 0.0;
      final duration = (data['total_duration_s'] as num?)?.toInt() ?? 0;
      final route = RouteCache(
        polyline: polyline,
        distance: distance,
        duration: duration,
        fetchedAt: DateTime.now(),
      );
      _routeCache[key] = route;
      state = state.copyWith(route: route);
      return route;
    } catch (_) {
      return null;
    }
  }

  double _approxDistance(double lat1, double lng1, double lat2, double lng2) {
    // Rough approximation using haversine (simplified for this plan).
    const R = 6371000; // meters
    final dLat = (lat2 - lat1) * (3.141592653589793 / 180);
    final dLng = (lng2 - lng1) * (3.141592653589793 / 180);
    final a = (dLat / 2) * (dLat / 2) +
        (dLng / 2) * (dLng / 2) * cos(lat1 * 3.141592653589793 / 180);
    final c = 2 * sqrt(a);
    return R * c;
  }
}

final tripNotifierProvider = StateNotifierProvider<TripNotifier, TripState>((ref) {
  return TripNotifier(ref);
});
