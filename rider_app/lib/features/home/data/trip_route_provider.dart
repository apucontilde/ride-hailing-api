import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../model/ride_stop.dart';
import 'home_provider.dart' show NavigationRoute;

/// How the active trip's road route is doing.
///
/// [estimate] and [unavailable] are deliberately distinct from [ready]: the
/// former has a route-shaped polyline the API itself flagged as not road
/// following, the latter has no trustworthy geometry at all. Neither may be
/// drawn as a confident solid line.
enum TripRouteStatus { idle, loading, ready, estimate, unavailable }

class TripRouteState {
  final TripRouteStatus status;

  /// The road-following geometry, concatenated across the itinerary legs. Only
  /// populated for [TripRouteStatus.ready] and [TripRouteStatus.estimate].
  final List<LatLng> polyline;
  final double totalDistanceM;
  final double totalDurationS;

  /// Why the route is an estimate (coverage gap / cross-region) or why it is
  /// unavailable (the API's own error message). Rendered verbatim.
  final String? message;
  final DateTime? fetchedAt;

  const TripRouteState({
    this.status = TripRouteStatus.idle,
    this.polyline = const [],
    this.totalDistanceM = 0,
    this.totalDurationS = 0,
    this.message,
    this.fetchedAt,
  });

  bool get hasRoadRoute => status == TripRouteStatus.ready;
  bool get isEstimate => status == TripRouteStatus.estimate;
  bool get hasError => status == TripRouteStatus.unavailable;
}

/// The interval at which [TripRouteNotifier] re-reads the trip. Injectable so a
/// widget test can exercise the tick without a real delay.
final tripRouteRefreshIntervalProvider =
    Provider<Duration>((ref) => const Duration(seconds: 30));

/// The acting trip's road route (pickup → intermediate stops → dropoff) plus a
/// live refresh.
///
/// Owns the whole read: `GET /rides/:id` supplies the pickup, the dropoff and
/// the additive `stops` itinerary, then each consecutive pair is routed through
/// `GET /navigation/route` and the legs are concatenated. A missing `stops`
/// key degrades to a single pickup→dropoff leg rather than failing.
///
/// **Honesty contract.** A route the API flags `is_estimate: true`, or any
/// failed leg, never becomes a silent straight line: the estimate keeps the
/// API's geometry but [TripRouteStatus.estimate] makes the screen draw it
/// dashed behind an explicit "Estimated route" banner, and a failure yields
/// [TripRouteStatus.unavailable] with **no** polyline at all.
class TripRouteNotifier extends StateNotifier<TripRouteState> {
  TripRouteNotifier(
    this._apiClient, {
    this.refreshInterval = const Duration(seconds: 30),
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        super(const TripRouteState());

  final ApiClient _apiClient;
  final Duration refreshInterval;
  final DateTime Function() _now;

  static const String _estimateReason =
      'Part of this trip is outside the mapped road network.';
  static const String _routeUnavailable =
      'No road route is available right now.';

  Timer? _timer;
  bool _disposed = false;
  int _loadToken = 0;
  String? _rideId;

  /// The id most recently passed to [load]; the refresh tick re-reads it.
  @visibleForTesting
  String? get rideId => _rideId;

  /// Arms the refresh tick. Idempotent, so a rebuild or a lifecycle resume
  /// cannot stack timers.
  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(refreshInterval, (_) {
      final rideId = _rideId;
      if (rideId != null) unawaited(load(rideId));
    });
  }

  /// Cancels the refresh tick. Called on dispose and on `completed` /
  /// `cancelled` — there is nothing left to route once the ride is over.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  bool get isPolling => _timer != null;

  /// Reads the itinerary and routes every leg. Concurrent calls are ordered by
  /// a token so a slow earlier response cannot overwrite a newer one.
  Future<void> load(String rideId) async {
    if (_disposed) return;
    _rideId = rideId;
    final token = ++_loadToken;
    // A refresh keeps the route already on screen until the new one lands —
    // only a first load has nothing to keep and shows the loading state.
    if (state.polyline.isEmpty) {
      state = const TripRouteState(status: TripRouteStatus.loading);
    }
    try {
      final response = await _apiClient.dio.get(ApiEndpoints.rideById(rideId));
      final data = response.data as Map<String, dynamic>? ?? const {};
      final ride = data['ride'];
      if (ride is! Map<String, dynamic>) {
        _fail(token, 'This ride could not be found.');
        return;
      }

      final pickupLat = (ride['pickup_lat'] as num?)?.toDouble();
      final pickupLng = (ride['pickup_lng'] as num?)?.toDouble();
      final dropoffLat = (ride['dropoff_lat'] as num?)?.toDouble();
      final dropoffLng = (ride['dropoff_lng'] as num?)?.toDouble();
      if (pickupLat == null ||
          pickupLng == null ||
          dropoffLat == null ||
          dropoffLng == null) {
        _fail(token, 'This ride has no routeable pickup or dropoff.');
        return;
      }

      // `stops` is additive: absent (an older server) means a single leg.
      final stops = (data['stops'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RideStop.fromJson)
          .toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));

      final points = <LatLng>[LatLng(pickupLat, pickupLng)];
      for (final stop in stops) {
        final point = LatLng(stop.lat, stop.lng);
        if (points.last != point) points.add(point);
      }
      final dropoff = LatLng(dropoffLat, dropoffLng);
      // The destination stop mirrors `dropoff_lat/lng`; do not duplicate it.
      if (points.last != dropoff) points.add(dropoff);

      if (points.length < 2) {
        _fail(token, 'This trip has no distance to route.');
        return;
      }

      final polyline = <LatLng>[];
      var estimate = false;
      double distance = 0;
      double duration = 0;

      for (var i = 0; i < points.length - 1; i++) {
        final from = points[i];
        final to = points[i + 1];
        if (from == to) continue;
        final leg = await _fetchLeg(from, to);
        if (_disposed || token != _loadToken) return;
        if (leg.polyline.length < 2) {
          _fail(token, 'The route came back incomplete.');
          return;
        }
        if (leg.isEstimate) estimate = true;
        distance += leg.totalDistanceM;
        duration += leg.totalDurationS;
        for (final point in leg.polyline) {
          if (polyline.isNotEmpty && polyline.last == point) continue;
          polyline.add(point);
        }
      }

      if (polyline.length < 2) {
        _fail(token, _routeUnavailable);
        return;
      }

      if (_disposed || token != _loadToken) return;
      state = TripRouteState(
        status:
            estimate ? TripRouteStatus.estimate : TripRouteStatus.ready,
        polyline: List<LatLng>.unmodifiable(polyline),
        totalDistanceM: distance,
        totalDurationS: duration,
        message: estimate ? _estimateReason : null,
        fetchedAt: _now(),
      );
    } on DioException catch (e) {
      _fail(token, apiErrorMessage(e, _routeUnavailable));
    } catch (_) {
      // A malformed body is not a route either; never fall through to a
      // synthesized straight line.
      _fail(token, _routeUnavailable);
    }
  }

  Future<NavigationRoute> _fetchLeg(LatLng from, LatLng to) async {
    final response = await _apiClient.dio.get(
      ApiEndpoints.navigationRoute,
      queryParameters: {
        'from_lat': from.latitude,
        'from_lng': from.longitude,
        'to_lat': to.latitude,
        'to_lng': to.longitude,
      },
    );
    return NavigationRoute.fromJson(response.data as Map<String, dynamic>);
  }

  void _fail(int token, String message) {
    if (_disposed || token != _loadToken) return;
    state = TripRouteState(
      status: TripRouteStatus.unavailable,
      message: message,
      fetchedAt: _now(),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

final tripRouteProvider =
    StateNotifierProvider<TripRouteNotifier, TripRouteState>((ref) {
  return TripRouteNotifier(
    ref.read(apiClientProvider),
    refreshInterval: ref.read(tripRouteRefreshIntervalProvider),
  );
});
