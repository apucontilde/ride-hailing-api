import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../../features/driver/model/driver_profile.dart';
import '../api/endpoints.dart';
import '../network/websocket_service.dart';

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
        error: e.message ?? 'Driver registration failed. Please try again.',
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