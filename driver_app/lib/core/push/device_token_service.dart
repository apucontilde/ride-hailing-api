import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../api/endpoints.dart';
import '../auth/auth_provider.dart';
import '../../features/home/providers/availability_notifier.dart';
import 'push_token_source.dart';

/// Owns the device-token lifecycle: register the current token with the API
/// once the driver is authenticated or online, re-register when the SDK rotates
/// the token, and unregister on sign-out while the bearer is still valid.
///
/// Every network call is best-effort and swallowed: a push failure must never
/// gate auth, the online toggle, or sign-out. Registration also requires a
/// non-null token — the default [NoopPushTokenSource] returns none, so the whole
/// service degrades to a no-op until a real SDK is installed.
///
/// The raw token is never logged, not even in a failure path.
class DeviceTokenService {
  final ApiClient apiClient;
  final PushTokenSource tokenSource;
  final DevicePlatform Function() platform;

  StreamSubscription<String>? _refreshSub;
  String? _registeredToken;

  DeviceTokenService({
    required this.apiClient,
    required this.tokenSource,
    DevicePlatform Function()? platform,
  }) : platform = platform ?? currentDevicePlatform;

  /// Subscribes to the SDK token-refresh stream. Safe to call more than once.
  void start() {
    if (_refreshSub != null) return;
    _refreshSub = tokenSource.onTokenRefresh.listen(
      (token) => registerToken(token),
      onError: (_) {
        // A broken refresh stream must not take the app down.
      },
    );
  }

  void dispose() {
    _refreshSub?.cancel();
    _refreshSub = null;
  }

  /// Fetches the current token and registers it. No token (permission denied,
  /// no SDK, unsupported platform) means no server call.
  Future<void> register() async {
    String? token;
    try {
      token = await tokenSource.getToken();
    } catch (_) {
      return;
    }
    if (token == null || token.trim().isEmpty) return;
    await registerToken(token);
  }

  /// Upserts [token] for the signed-in user. Idempotent server-side.
  Future<void> registerToken(String token) async {
    if (token.trim().isEmpty) return;
    try {
      await apiClient.dio.post(
        ApiEndpoints.devices,
        data: {'token': token, 'platform': platform().wireValue},
      );
      _registeredToken = token;
    } catch (_) {
      // Non-fatal: the pipeline is reachable but delivery is not on this path.
    }
  }

  /// Deactivates the last token we registered for this device. Must be called
  /// before the access token is cleared (see `AuthNotifier.logout`). A no-op
  /// when nothing was registered; never throws.
  Future<void> unregister() async {
    final token = _registeredToken;
    if (token == null || token.trim().isEmpty) return;
    try {
      await apiClient.dio.delete(ApiEndpoints.deviceUnregister(token));
    } catch (_) {
      // Defense in depth only — the server reassigns on the next register.
    }
    _registeredToken = null;
  }
}

/// Wires the service to its registration triggers and keeps it alive for the
/// life of the container:
///
/// - the driver session becoming authenticated: `AuthNotifier.onAuthenticated`
///   calls [DeviceTokenService.register] (login, registration, cold-start
///   `/me`, token rotation), mirroring the rider,
/// - the driver's availability becoming online,
/// - the SDK's token-refresh stream (inside [DeviceTokenService.start]).
///
/// It deliberately does **not** `ref.listen` on `authProvider`: `logout()` reads
/// this provider back to unregister before clearing the bearer, and a listener
/// edge the other way forms a Riverpod dependency cycle (auth → service must
/// stay one-directional). It observes availability separately from the websocket
/// keep-alive wiring in `location_service.dart` and never touches
/// `AvailabilityNotifier.onOnlineChanged`.
final deviceTokenServiceProvider = Provider<DeviceTokenService>((ref) {
  final service = DeviceTokenService(
    apiClient: ref.read(apiClientProvider),
    tokenSource: ref.read(pushTokenSourceProvider),
  );

  ref.listen<AvailabilityState>(
    availabilityProvider,
    (previous, next) {
      if (next.online) service.register();
    },
  );

  service.start();
  ref.onDispose(service.dispose);
  return service;
});
