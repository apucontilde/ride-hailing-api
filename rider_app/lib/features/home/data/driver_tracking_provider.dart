import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../model/driver.dart';
import 'ride_status_provider.dart';

class DriverTrackingState {
  final DriverLocation? location;
  final int httpPolls;
  final String? error;

  const DriverTrackingState({
    this.location,
    this.httpPolls = 0,
    this.error,
  });

  DriverTrackingState copyWith({
    DriverLocation? location,
    int? httpPolls,
    String? error,
  }) {
    return DriverTrackingState(
      location: location ?? this.location,
      httpPolls: httpPolls ?? this.httpPolls,
      error: error,
    );
  }
}

/// The HTTP half of live tracking (LC-4): when the `driver.location` WS event
/// goes quiet, ask `GET /drivers/{id}/location` instead so the rider's marker
/// keeps moving.
///
/// **Timing.** Silence is counted in poll *ticks*, not wall-clock milliseconds:
/// the tick is armed for [pollInterval] (5 s) and a poll fires once
/// [wsSilenceTimeout] (10 s) of ticks have gone by without any location update
/// from either channel. That is the same schedule a wall clock would produce at
/// the default values, but it makes the behaviour exactly reproducible under
/// `tester.pump` (which elapses the test framework's fake clock and nothing
/// else) and needs no clock injection. Both durations are constructor
/// parameters, so a unit test can run the whole thing on real timers in
/// milliseconds.
///
/// The polled fix is written back into [rideStatusProvider] rather than kept in
/// a parallel store, so the screen has ONE source of truth for the marker —
/// the WS event and the HTTP fallback are indistinguishable downstream.
class DriverTrackingNotifier extends StateNotifier<DriverTrackingState> {
  DriverTrackingNotifier(
    this._apiClient,
    this._ref, {
    this.pollInterval = const Duration(seconds: 5),
    this.wsSilenceTimeout = const Duration(seconds: 10),
  }) : super(const DriverTrackingState());

  final ApiClient _apiClient;
  final Ref _ref;
  final Duration pollInterval;
  final Duration wsSilenceTimeout;

  Timer? _timer;
  String? _driverId;
  int _silentTicks = 0;
  bool _inFlight = false;
  bool _disposed = false;

  /// The driver id from the accepted payload — the path parameter of
  /// `GET /drivers/{id}/location`. `null` until the accept event arrives, and
  /// polls are a no-op until then.
  void attach(String? driverId) {
    _driverId = driverId;
  }

  /// Arms the 5 s tick. Idempotent, so a rebuild or a lifecycle resume cannot
  /// stack timers.
  void start() {
    if (_timer != null) return;
    _silentTicks = 0;
    _timer = Timer.periodic(pollInterval, (_) => _tick());
  }

  /// Cancels the tick. Called on dispose and on `completed` / `cancelled` —
  /// there is nothing left to track once the ride is over.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// A `driver.location` WS event arrived: publish it and restart the silence
  /// window. Fed from the screen's listener on `RideState.driverLocation` so
  /// the WS and HTTP paths cannot diverge.
  void noteWsLocation(DriverLocation location) {
    _silentTicks = 0;
    if (_disposed) return;
    state = state.copyWith(location: location);
  }

  @visibleForTesting
  bool get isPolling => _timer != null;

  /// Ticks of silence that still fit inside [wsSilenceTimeout]. Exposed so a
  /// test can assert the schedule, not just the outcome.
  @visibleForTesting
  int get silentTicks => _silentTicks;

  void _tick() {
    _silentTicks++;
    if (_silentTicks * pollInterval.inMilliseconds <
        wsSilenceTimeout.inMilliseconds) {
      return;
    }
    unawaited(pollNow());
  }

  /// One `GET /drivers/{id}/location`, folded into `rideStatusProvider`.
  /// Overlapping ticks are dropped, and a 404 (the driver app never pushed a
  /// position) is surfaced rather than retried in a tight loop.
  Future<void> pollNow() async {
    final driverId = _driverId;
    if (driverId == null || _inFlight || _disposed) return;
    _inFlight = true;
    try {
      final response = await _apiClient.dio
          .get(ApiEndpoints.driverLocation(driverId));
      final location = DriverLocation.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      _silentTicks = 0;
      if (_disposed) return;
      state = state.copyWith(location: location, httpPolls: state.httpPolls + 1);
      _ref.read(rideStatusProvider.notifier).applyDriverLocation(location);
    } on DioException catch (e) {
      if (_disposed) return;
      state = state.copyWith(
        httpPolls: state.httpPolls + 1,
        error: apiErrorMessage(e, 'Could not refresh driver location'),
      );
    } catch (_) {
      // A malformed body must not kill the tick; the next one tries again.
    } finally {
      _inFlight = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}

final driverTrackingProvider =
    StateNotifierProvider<DriverTrackingNotifier, DriverTrackingState>((ref) {
  return DriverTrackingNotifier(ref.read(apiClientProvider), ref);
});
