import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/api/api_client.dart';
import '../../driver/model/driver_profile.dart';

/// Mirrors the server `status` (`online`/`offline`) and exposes a switch
/// that pushes `PUT /driver/me/status`. Double-tap guarded.
class AvailabilityState {
  final bool online;
  final bool inFlight;
  final String? error;

  const AvailabilityState({
    this.online = false,
    this.inFlight = false,
    this.error,
  });

  AvailabilityState copyWith({
    bool? online,
    bool? inFlight,
    String? error,
  }) {
    return AvailabilityState(
      online: online ?? this.online,
      inFlight: inFlight ?? this.inFlight,
      error: error,
    );
  }
}

class AvailabilityNotifier extends StateNotifier<AvailabilityState> {
  final Ref _ref;

  AvailabilityNotifier(this._ref) : super(const AvailabilityState());

  /// Invoked with the resulting online flag whenever availability is
  /// (re)evaluated. The driver app wires this to the websocket keep-alive so
  /// an offline driver stops pinging and an online driver (re)starts it.
  void Function(bool online)? onOnlineChanged;

  ApiClient get _apiClient => _ref.read(apiClientProvider);

  bool get online => state.online;
  bool get inFlight => state.inFlight;
  String? get error => state.error;

  /// Sync from the server profile (called by auth/profile updates).
  void syncFromProfile(DriverProfile? profile) {
    final isOnline = profile?.isOnline ?? false;
    if (isOnline != state.online) {
      state = state.copyWith(online: isOnline, error: null);
    }
    // Fire even when the flag did not change so a freshly built app with an
    // offline profile still tears down any heartbeat the connect started.
    onOnlineChanged?.call(state.online);
  }

  void setOnline() {
    if (state.inFlight) return;
    if (state.online) return;
    state = state.copyWith(online: true, error: null);
    onOnlineChanged?.call(state.online);
  }

  void setOffline() {
    if (state.inFlight) return;
    if (!state.online) return;
    state = state.copyWith(online: false, error: null);
    onOnlineChanged?.call(state.online);
  }

  Future<void> toggle() async {
    if (state.inFlight) return;
    final target = !state.online;
    state = state.copyWith(inFlight: true, error: null);
    try {
      final response = await _apiClient.dio.put(
        ApiEndpoints.driverMeStatus,
        data: {'status': target ? 'online' : 'offline'},
      );
      final data = response.data as Map<String, dynamic>;
      final driverData = data['driver'] as Map<String, dynamic>? ?? {};
      final profile = DriverProfile.fromJson(driverData);
      // The status flip must be written back into the shared profile cache.
      //
      // This is the bug behind "the driver never sees an offer": the switch
      // drove `availabilityProvider` (so the UI said "You're online") but left
      // `driverProfileProvider` at the status the auth bootstrap cached. The
      // home screen gates the offer sheet on `driverProfileProvider`'s
      // `isOnline`, so every offer delivered over the websocket was dropped on
      // the floor and then expired after 30 s. Mirrors what
      // `ProfileNotifier.updateProfile` already does on a profile save.
      _ref.read(driverProfileProvider.notifier).state = profile;
      state = AvailabilityState(
        online: profile.isOnline,
        inFlight: false,
        error: null,
      );
      onOnlineChanged?.call(state.online);
    } catch (e) {
      // Revert to previous state on failure.
      state = state.copyWith(
        online: state.online,
        inFlight: false,
        error: e is Exception ? e.toString() : 'Failed to update status',
      );
      // Re-assert the (unchanged) flag so the heartbeat follows the server
      // truth after a failed flip.
      onOnlineChanged?.call(state.online);
    }
  }
}

final availabilityProvider =
    StateNotifierProvider<AvailabilityNotifier, AvailabilityState>((ref) {
  return AvailabilityNotifier(ref);
});
