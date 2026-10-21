import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/auth/auth_provider.dart';
import 'ride_status_provider.dart';

class CurrentRideState {
  final bool loading;
  final String? status;
  final String? rideId;
  final bool noDriverAvailable;
  final bool stillSearching;
  final bool needsRestore;
  final bool searchTimedOut;
  final String? error;

  const CurrentRideState({
    this.loading = false,
    this.status,
    this.rideId,
    this.noDriverAvailable = false,
    this.stillSearching = false,
    this.needsRestore = false,
    this.searchTimedOut = false,
    this.error,
  });

  CurrentRideState copyWith({
    bool? loading,
    String? status,
    String? rideId,
    bool? noDriverAvailable,
    bool? stillSearching,
    bool? needsRestore,
    bool? searchTimedOut,
    String? error,
  }) {
    return CurrentRideState(
      loading: loading ?? this.loading,
      status: status ?? this.status,
      rideId: rideId ?? this.rideId,
      noDriverAvailable: noDriverAvailable ?? this.noDriverAvailable,
      stillSearching: stillSearching ?? this.stillSearching,
      needsRestore: needsRestore ?? this.needsRestore,
      searchTimedOut: searchTimedOut ?? this.searchTimedOut,
      error: error ?? this.error,
    );
  }
}

/// Polls `GET /rides/current` while a ride is being created, so the ride
/// state machine keeps working even when no WS event arrives (e.g. the
/// backend transitions the ride to `no_driver_available` without pushing,
/// or the WS connection drops). Also lets a cold app restore an active ride.
class CurrentRideNotifier extends StateNotifier<CurrentRideState> {
  final ApiClient _apiClient;
  final Ref _ref;
  final DateTime Function() _now;
  Timer? _timer;
  DateTime? _startedAt;
  int _attempts = 0;

  static const int maxAttempts = 60; // ~5 min at default interval
  static const Duration stillSearchingAfter = Duration(seconds: 30);

  CurrentRideNotifier(this._apiClient, this._ref, {DateTime Function()? now})
    : _now = now ?? DateTime.now,
      super(const CurrentRideState());

  void startPolling({Duration interval = const Duration(seconds: 5)}) {
    stopPolling();
    _attempts = 0;
    _startedAt = _now();
    state = const CurrentRideState();
    _timer = Timer.periodic(interval, (_) => pollNow());
    pollNow();
  }

  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  bool get isPolling => _timer != null;

  bool _isTerminalStatus(String? status) =>
      status == 'no_driver_available' ||
      status == 'cancelled' ||
      status == 'completed';

  /// Single immediate poll used at cold start to restore an ongoing ride.
  ///
  /// Uncapped on purpose: a stale `_attempts` from a previous session must never
  /// turn the post-login restore into a no-op. The whole prior view is cleared
  /// first, so a `{ride: null}` response cannot be mistaken for a ride from the
  /// previous session vanishing (which would fabricate `no_driver_available`)
  /// and the timeout flag cannot route the fresh session.
  Future<void> checkOnce() async {
    _attempts = 0;
    // A one-shot restore starts a fresh search window: without this the prior
    // session's elapsed time could immediately render `stillSearching`.
    _startedAt = null;
    state = const CurrentRideState();
    await pollNow();
  }

  /// Clears the poll's view of the current ride and its bookkeeping.
  ///
  /// Called when a trip reaches a terminal state and the rider leaves the trip
  /// screen: the last poll can still hold an active status, which would make the
  /// router's restore redirect bounce a completed ride straight back to the
  /// trip. Resetting keeps `needsRestore` false for the post-trip Home. It is
  /// also the session boundary (logout / account switch), so a previous rider's
  /// status cannot survive into the next login.
  void reset() {
    stopPolling();
    _attempts = 0;
    _startedAt = null;
    state = const CurrentRideState();
  }

  Future<void> pollNow() async {
    if (_attempts >= maxAttempts) {
      // Truthful terminal state: keep the last real backend status (it may
      // still be `pending`) and never fabricate `no_driver_available`.
      stopPolling();
      state = state.copyWith(
        loading: false,
        stillSearching: false,
        searchTimedOut: true,
      );
      return;
    }
    _attempts++;
    state = state.copyWith(loading: true, error: null);
    try {
      final response = await _apiClient.dio.get(ApiEndpoints.currentRide);
      final ride = (response.data as Map<String, dynamic>?)?['ride'];
      state = _deriveState(ride is Map<String, dynamic> ? ride : null);
      _ref
          .read(rideStatusProvider.notifier)
          .updateFromCurrentRide(ride is Map<String, dynamic> ? ride : null);
      if (state.noDriverAvailable || _isTerminalStatus(state.status)) {
        stopPolling();
      }
    } on DioException catch (e) {
      state = state.copyWith(
        loading: false,
        error: apiErrorMessage(e, 'Failed to load ride'),
      );
    } catch (_) {
      state = state.copyWith(loading: false);
    }
  }

  CurrentRideState _deriveState(Map<String, dynamic>? ride) {
    _startedAt ??= _now();
    if (ride == null) {
      // A ride we were tracking vanished (moved to no_driver_available and
      // dropped) — treat it as "no drivers". If we never saw a ride, keep
      // searching and escalate the copy after a grace period.
      if (state.rideId != null) {
        return const CurrentRideState(
          status: 'no_driver_available',
          noDriverAvailable: true,
        );
      }
      final elapsed = _now().difference(_startedAt!);
      return state.copyWith(
        loading: false,
        stillSearching: elapsed >= stillSearchingAfter,
      );
    }

    final status = ride['status'] as String?;
    final rideId = ride['id'] as String?;
    // The active set `GET /rides/current` actually returns. `pending` maps to
    // the matching screen, so it must restore too; `completed` is **never**
    // returned by the endpoint (its query excludes it) — keeping it here would
    // be dead. `cancelled` / `no_driver_available` never restore.
    final restore =
        status == 'pending' ||
        status == 'accepted' ||
        status == 'driver_arrived' ||
        status == 'in_progress';

    return CurrentRideState(
      loading: false,
      status: status,
      rideId: rideId,
      noDriverAvailable: status == 'no_driver_available',
      stillSearching: false,
      needsRestore: restore,
    );
  }
}

final currentRideProvider =
    StateNotifierProvider<CurrentRideNotifier, CurrentRideState>((ref) {
      final apiClient = ref.read(apiClientProvider);
      return CurrentRideNotifier(apiClient, ref);
    });
