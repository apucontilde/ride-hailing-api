import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../../features/driver/model/driver_profile.dart';
import '../api/endpoints.dart';
import '../network/websocket_service.dart';
import '../push/device_token_service.dart';

export 'package:ride_hailing_shared/ride_hailing_shared.dart'
    show AuthStatus, AuthState;

final authStorageProvider = Provider<AuthStorage>((ref) => AuthStorage());

final apiClientProvider =
    Provider<ApiClient>((ref) => ApiClient(baseUrl: ApiConfig.baseUrl));

/// The live driver profile from `GET /driver/me`, maintained by [AuthNotifier].
final driverProfileProvider = StateProvider<DriverProfile?>((ref) => null);

class AuthNotifier extends AppAuthController {
  final Ref _ref;

  AuthNotifier(
    this._ref, {
    required super.authStorage,
    required super.apiClient,
    required super.webSocketService,
  }) : super(
          loginEndpoint: ApiEndpoints.login,
          registerEndpoint: ApiEndpoints.register,
          refreshTokenEndpoint: ApiEndpoints.refreshToken,
          logoutEndpoint: ApiEndpoints.logout,
        );

  @override
  bool shouldConnectWebSocket(AuthUser user) => user.isDriver;

  @override
  Future<AuthUser> fetchMe() async {
    final driver = await _fetchDriver();
    _setDriver(driver);
    return AuthUser(id: driver.userId, role: 'driver', status: driver.status);
  }

  @override
  Future<void> onAuthenticated(AuthUser user) async {
    // Register the push device token on every authenticated transition (login,
    // registration, cold-start `/me`) so the token reassigns to the current
    // account. Best-effort and fire-and-forget: a push failure must never gate
    // auth. The device service is read from here rather than from a provider
    // listener on `authProvider`, which would form a Riverpod dependency cycle
    // with `logout()` reading it back. Mirrors the rider.
    unawaited(_ref.read(deviceTokenServiceProvider).register());

    // Seed the driver profile whenever the session role becomes `driver`
    // (login, token rotation). Non-fatal — /home surfaces via refreshProfile.
    if (!user.isDriver) return;
    try {
      final driver = await _fetchDriver();
      _setDriver(driver);
    } catch (_) {
      // Non-fatal — /home will surface profile load via refreshProfile.
    }
  }

  @override
  Future<void> onLoggedOut() async {
    // Without this the previous driver's profile (including `status: online`)
    // survives sign-out and is still in the container for the next session.
    _ref.read(driverProfileProvider.notifier).state = null;
  }

  @override
  Future<void> logout() async {
    // Unregister the push token while the access token is still installed:
    // `super.logout()` calls `apiClient.setToken(null)` before `onLoggedOut()`,
    // so a DELETE issued from there would 401 and never reach the server. This
    // one seam covers both UI sign-out call sites (settings screen and the
    // shell drawer) and the switch-account path. Best-effort — an unregister
    // failure (or the service being unwired) must never block sign-out.
    try {
      await _ref.read(deviceTokenServiceProvider).unregister();
    } catch (_) {
      // Swallow: local cleanup is the priority.
    }
    await super.logout();
  }

  Future<DriverProfile> _fetchDriver() async {
    final response = await apiClient.dio.get(ApiEndpoints.driverMe);
    final data = response.data as Map<String, dynamic>;
    final driverData = data['driver'] as Map<String, dynamic>? ?? {};
    return DriverProfile.fromJson(driverData);
  }

  void _setDriver(DriverProfile driver) {
    _ref.read(driverProfileProvider.notifier).state = driver;
  }

  /// Promotes the authenticated rider account to a driver (US-D1). The token
  /// carries the `rider` role until login again, so after promotion we refresh
  /// the token so subsequent role-gated calls succeed.
  Future<bool> registerAsDriver() async {
    state = state.copyWith(status: AuthStatus.loading, error: null);
    try {
      await apiClient.dio.post(ApiEndpoints.driverRegister);
      // Role lives in the JWT, so rotate the access token to pick up `driver`.
      final ok = await refreshToken();
      if (!ok) return false;
      final driver = await _fetchDriver();
      _setDriver(driver);
      state = AuthState(
        status: AuthStatus.authenticated,
        user: AuthUser(
          id: driver.userId,
          role: 'driver',
          status: driver.status,
        ),
      );
      return true;
    } on ApiException catch (e) {
      state = state.copyWith(status: AuthStatus.authenticated, error: e.message);
      return false;
    } on DioException catch (e) {
      state = state.copyWith(
        status: AuthStatus.authenticated,
        error: apiErrorMessage(e, 'Driver registration failed. Please try again.'),
      );
      return false;
    }
  }

  Future<void> refreshProfile() async {
    if (!state.isDriver) return;
    try {
      final driver = await _fetchDriver();
      _setDriver(driver);
      state = state.copyWith(
        user: AuthUser(id: driver.userId, role: 'driver', status: driver.status),
      );
    } catch (_) {
      // Non-fatal — keep current session state.
    }
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final notifier = AuthNotifier(
    ref,
    authStorage: ref.read(authStorageProvider),
    apiClient: ref.read(apiClientProvider),
    webSocketService: ref.read(webSocketServiceProvider),
  );
  // Install the 401 refresh callback so the API client can transparently
  // refresh and retry when the access token expires mid-session.
  ref.read(apiClientProvider).unauthorizedHandler = notifier.refreshToken;
  return notifier;
});