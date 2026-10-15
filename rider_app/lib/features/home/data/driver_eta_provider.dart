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
  RideStatus _status = RideStatus.idle;
  LatLng? _referenceFix;
  DateTime? _lastRequestAt;
  Future<void>? _lastCompute;

  /// Bumped by [_resetThrottle] at every ride boundary. A `/geo/eta` response is
  /// only allowed to touch [_referenceFix] or `RideState` while its captured
  /// generation still matches, so a response left in flight across a boundary
  /// cannot leak into the next ride.
  int _generation = 0;

  /// The generation whose request is currently in flight, or null when none is.
  /// Scoped to a generation rather than a plain bool so a stale request cannot
  /// swallow the next ride's immediate compute.
  int? _inFlightGeneration;

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
    // Capture the entry edge before overwriting `_status`: a new ride must not
    // inherit the previous ride's throttle bookkeeping (bug #30). `stop()` also
    // resets, but this keeps the "entering `driverApproaching`" intent visible
    // and independent of `stop()`'s idempotence.
    final wasApproaching = _status == RideStatus.driverApproaching;
    _status = rideState.status;
    if (_status != RideStatus.driverApproaching) {
      stop();
      return;
    }
    if (!wasApproaching) _resetThrottle();
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

  /// Cancels the tick and drops the per-ride throttle bookkeeping. Called on
  /// every transition out of `driverApproaching` (which includes every terminal
  /// status) and on dispose.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _resetThrottle();
  }

  /// Clears the per-ride throttle bookkeeping so the next ride's first fix is
  /// computed immediately, and bumps [_generation] so any `/geo/eta` response
  /// still in flight for the previous ride is discarded when it lands. Does
  /// **not** touch [state] or `RideState` — the authoritative ETA and the
  /// `300`-unknown contract are untouched.
  void _resetThrottle() {
    _generation++;
    _referenceFix = null;
    _lastRequestAt = null;
    _lastCompute = null;
    // `_inFlightGeneration` is deliberately NOT cleared here: a request in
    // flight for the previous generation still owns its own `finally`, and
    // because the marker no longer matches the current generation the new
    // ride's immediate compute below is not swallowed.
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
    if (_disposed) return;
    final generation = _generation;
    // A request for the *current* generation is already in flight and must not
    // be duplicated; one left over from a previous generation must not block
    // this ride's immediate compute (bug #30 residual).
    if (_inFlightGeneration == generation) return;
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
    _inFlightGeneration = generation;
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
      // A ride boundary that fired while this request was in flight makes the
      // response stale: it must neither re-set `_referenceFix` nor write the
      // ETA into the (now different) current `RideState`.
      if (_disposed || generation != _generation) return;
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
      if (_disposed || generation != _generation) return;
      // Keep the previous ETA — do not clear it on an outage.
      state = state.copyWith(
        error: apiErrorMessage(e, 'Could not refresh ETA'),
      );
    } catch (_) {
      if (_disposed || generation != _generation) return;
    } finally {
      // Only the request that owns the marker may clear it, so a stale request
      // landing after the next ride's request started cannot unlock a duplicate.
      if (_inFlightGeneration == generation) _inFlightGeneration = null;
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
