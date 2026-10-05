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
  final String? error;

  const CurrentRideState({
    this.loading = false,
    this.status,
    this.rideId,
    this.noDriverAvailable = false,
    this.stillSearching = false,
    this.needsRestore = false,
    this.error,
  });

  CurrentRideState copyWith({
    bool? loading,
    String? status,
    String? rideId,
    bool? noDriverAvailable,
    bool? stillSearching,
    bool? needsRestore,
    String? error,
  }) {
    return CurrentRideState(
      loading: loading ?? this.loading,
      status: status ?? this.status,
      rideId: rideId ?? this.rideId,
      noDriverAvailable: noDriverAvailable ?? this.noDriverAvailable,
      stillSearching: stillSearching ?? this.stillSearching,
      needsRestore: needsRestore ?? this.needsRestore,
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

  CurrentRideNotifier(
    this._apiClient,
    this._ref, {
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
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
  Future<void> checkOnce() => pollNow();

  Future<void> pollNow() async {
    if (_attempts >= maxAttempts) {
      stopPolling();
      return;
    }
    _attempts++;
    state = state.copyWith(loading: true, error: null);
    try {
      final response = await _apiClient.dio.get(ApiEndpoints.currentRide);
      final ride = (response.data as Map<String, dynamic>?)?['ride'];
      state = _deriveState(ride is Map<String, dynamic> ? ride : null);
      _ref.read(rideStatusProvider.notifier)
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
    final restore =
        status == 'accepted' ||
        status == 'driver_arrived' ||
        status == 'in_progress' ||
        status == 'completed';

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