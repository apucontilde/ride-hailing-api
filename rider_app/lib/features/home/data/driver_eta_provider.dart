import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import 'ride_status_provider.dart';
import 'trip_eta.dart';

/// The result of the rider's client-side arrival-ETA compute (option R1 from
/// `[ontrip]_driver_arrival_eta.md`).
///
/// The authoritative number still lives on `RideState.etaSeconds`; this state is
/// the request bookkeeping a test (and the screen) can observe without a second
/// source of truth for the displayed ETA.
class DriverEtaState {
  /// Successful `/geo/eta` responses folded into `RideState`.
  final int computations;

  /// The last value written to `RideState.etaSeconds`, or null before any.
  final int? etaSeconds;
  final double? distanceM;
  final String? error;

  const DriverEtaState({
    this.computations = 0,
    this.etaSeconds,
    this.distanceM,
    this.error,
  });

  DriverEtaState copyWith({
    int? computations,
    int? etaSeconds,
    double? distanceM,
    String? error,
  }) {
    return DriverEtaState(
      computations: computations ?? this.computations,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      distanceM: distanceM ?? this.distanceM,
      error: error,
    );
  }
}

/// Client-computed **driver → pickup** ETA while the driver is approaching.
///
/// R1 in the plan: on each live driver fix (WS or the HTTP poll) while
/// [RideStatus.driverApproaching], ask `GET /api/v1/geo/eta` for the
/// driver→pickup leg and write the result into `RideState` via
/// [RideStatusNotifier.applyLiveEta]. This refreshes the accept-time number as
/// the driver moves and restores it after a reconnect/cold start (the poll
/// re-supplies a fix).
///
/// **Honesty:** the plan's `trip_eta.dart` contract is preserved — `300`/null/
/// non-positive is never written, and on a failed compute the previous value is
/// kept (this class simply does not call `applyLiveEta`).
class DriverEtaNotifier extends StateNotifier<DriverEtaState> {
  DriverEtaNotifier(
    this._apiClient,
    this._ref, {
    this.refreshInterval = const Duration(seconds: 30),
    this.minMovementM = 150,
    this.minInterval = const Duration(seconds: 5),
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        super(const DriverEtaState());

  final ApiClient _apiClient;
  final Ref _ref;
  final Duration refreshInterval;
  final double minMovementM;
  final Duration minInterval;
  final DateTime Function() _now;

  Timer? _timer;
  bool _disposed = false;
  bool _inFlight = false;
  RideStatus _status = RideStatus.idle;
  LatLng? _referenceFix;
  DateTime? _lastRequestAt;
  Future<void>? _lastCompute;

  @visibleForTesting
  bool get isPolling => _timer != null;

  /// The most recent in-flight compute, so a test can await it deterministically
  /// instead of racing Dio's response timer. Null before any fix.
  @visibleForTesting
  Future<void>? get pendingCompute => _lastCompute;

  /// Feeds the latest ride state in. Called on mount and on every
  /// `rideStatusProvider` change by the screen.
  void onRideState(RideState rideState) {
    if (_disposed) return;
    _status = rideState.status;
    if (_status != RideStatus.driverApproaching) {
      stop();
      return;
    }
    start();

    final fix = _fixFrom(rideState);
    final pickup = _pickupFrom(rideState);
    if (fix == null || pickup == null) return;

    // The first fix computes immediately (covers accept-then-fix and the
    // reconnect/cold-start rejoin); later fixes compute early only once the
    // driver has moved far enough from the fix the last ETA used. The 5 s floor
    // in `_compute` is authoritative on **both** paths, so a failed compute
    // cannot be retried faster than the floor either.
    final immediate = _referenceFix == null;
    if (immediate || _movedEnough(fix, _referenceFix!)) {
      _lastCompute = _compute(fix, pickup);
    }
  }

  /// Arms the interval tick. Idempotent, so a rebuild cannot stack timers.
  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(refreshInterval, (_) => _tick());
  }

  /// Cancels the tick. Called on terminal status and on dispose.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    final rideState = _ref.read(rideStatusProvider);
    if (rideState.status != RideStatus.driverApproaching) {
      stop();
      return;
    }
    final fix = _fixFrom(rideState);
    final pickup = _pickupFrom(rideState);
    if (fix != null && pickup != null) {
      _lastCompute = _compute(fix, pickup);
    }
  }

  Future<void> _compute(LatLng fix, LatLng pickup) async {
    if (_inFlight || _disposed) return;
    // The 5 s floor is authoritative whenever a request has already been made,
    // on the immediate AND movement paths. `_lastRequestAt` is stamped *before*
    // the request, so a **failed** compute burns the floor too — a failing
    // endpoint cannot be retried faster than the floor even though no successful
    // `_referenceFix` was recorded. The first fix after entering
    // `driverApproaching` has `_lastRequestAt == null` and is still immediate.
    if (_lastRequestAt != null &&
        _now().difference(_lastRequestAt!) < minInterval) {
      return;
    }
    _inFlight = true;
    _lastRequestAt = _now();
    try {
      final response = await _apiClient.dio.get(
        ApiEndpoints.eta,
        queryParameters: {
          'from_lat': fix.latitude,
          'from_lng': fix.longitude,
          'to_lat': pickup.latitude,
          'to_lng': pickup.longitude,
        },
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final seconds = (data['eta_seconds'] as num?)?.toInt();
      final distance = (data['distance_meters'] as num?)?.toDouble();
      if (_disposed) return;
      _referenceFix = fix;
      state = state.copyWith(
        computations: state.computations + 1,
        etaSeconds: seconds,
        distanceM: distance,
      );
      // Never write the unknown placeholder or a non-positive value.
      if (seconds != null && seconds > 0 && seconds != unknownEtaSeconds) {
        _ref
            .read(rideStatusProvider.notifier)
            .applyLiveEta(seconds, distanceM: distance);
      }
    } on DioException catch (e) {
      if (_disposed) return;
      // Keep the previous ETA — do not clear it on an outage.
      state = state.copyWith(
        error: apiErrorMessage(e, 'Could not refresh ETA'),
      );
    } catch (_) {
      if (_disposed) return;
    } finally {
      _inFlight = false;
    }
  }

  bool _movedEnough(LatLng a, LatLng b) =>
      const Distance().as(LengthUnit.Meter, a, b) >= minMovementM;

  LatLng? _fixFrom(RideState state) {
    final location = state.driverLocation ?? state.driver?.location;
    if (location == null) return null;
    return _toLatLng(location.lat, location.lng);
  }

  /// The pickup pin, from the accept payload's `pickup` or the REST
  /// `pickup_lat`/`pickup_lng` from `/rides/current` (so a cold start works).
  /// Never fabricated: a missing pin simply means no compute.
  LatLng? _pickupFrom(RideState state) {
    final data = state.rideData;
    if (data == null) return null;
    final pickup = data['pickup'];
    if (pickup is Map) {
      final lat = pickup['lat'];
      final lng = pickup['lng'];
      if (lat is num && lng is num) {
        return _toLatLng(lat.toDouble(), lng.toDouble());
      }
    }
    final lat = data['pickup_lat'];
    final lng = data['pickup_lng'];
    if (lat is num && lng is num) {
      return _toLatLng(lat.toDouble(), lng.toDouble());
    }
    return null;
  }

  static LatLng _toLatLng(double lat, double lng) => LatLng(lat, lng);

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

final driverEtaProvider =
    StateNotifierProvider<DriverEtaNotifier, DriverEtaState>((ref) {
  return DriverEtaNotifier(ref.read(apiClientProvider), ref);
});
