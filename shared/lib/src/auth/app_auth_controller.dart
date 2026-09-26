import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../models/auth_user.dart';
import '../network/websocket_service.dart';
import 'auth_storage.dart';

enum AuthStatus { unauthenticated, loading, authenticated }

class AuthState {
  final AuthStatus status;
  final AuthUser? user;
  final String? error;

  const AuthState({
    this.status = AuthStatus.unauthenticated,
    this.user,
    this.error,
  });

  AuthState copyWith({
    AuthStatus? status,
    AuthUser? user,
    String? error,
  }) {
    return AuthState(
      status: status ?? this.status,
      user: user ?? this.user,
      error: error,
    );
  }

  bool get isAuthenticated => status == AuthStatus.authenticated;
  bool get isLoading => status == AuthStatus.loading;

  /// True when the authenticated user carries the `driver` role. Both apps use
  /// this for role gating (rider app: on-boarding/driver screens; driver app:
  /// home access).
  bool get isDriver => user?.isDriver ?? false;
}

/// Shared auth controller providing the token lifecycle used by both apps:
/// `checkAuth` (cold-start `/me` probe), `login`, `register`, `refreshToken`,
/// `logout`, and remembered-email helpers.
///
/// Each app subclasses this and supplies the hook points that differ:
/// the `/me` profile endpoint and its user mapping ([fetchMe]), post-login
/// side effects ([onAuthenticated]), whether to open the websocket for a user
/// ([shouldConnectWebSocket]), and what a 403 from `/me` means
/// ([onForbiddenProfile]).
abstract class AppAuthController extends StateNotifier<AuthState> {
  final AuthStorage authStorage;
  final ApiClient apiClient;
  final WebSocketService webSocketService;

  final String loginEndpoint;
  final String registerEndpoint;
  final String refreshTokenEndpoint;
  final String logoutEndpoint;

  AppAuthController({
    required this.authStorage,
    required this.apiClient,
    required this.webSocketService,
    required this.loginEndpoint,
    required this.registerEndpoint,
    required this.refreshTokenEndpoint,
    required this.logoutEndpoint,
  }) : super(const AuthState());

  /// Fetches the signed-in user from the app's `/me` endpoint. Throws
  /// [ApiException] (e.g. [ForbiddenException]) on failure.
  Future<AuthUser> fetchMe();

  /// Hook invoked after a successful login/refresh so subclasses can attach
  /// extra state (e.g. seed a driver profile). Default does nothing.
  Future<void> onAuthenticated(AuthUser user) async {}

  /// Whether the websocket should be (re)connected for an authenticated user.
  /// Rider connects always; driver only when the user already carries the
  /// `driver` role.
  bool shouldConnectWebSocket(AuthUser user) => true;

  /// Handles a 403 from `fetchMe` (valid token but wrong role for the profile
  /// endpoint). Driver keeps the session so onboarding can promote the
  /// account; rider treats it like a bad session.
  Future<void> onForbiddenProfile() async {
    state = AuthState(
      status: AuthStatus.authenticated,
      user: AuthUser.fromRole('rider'),
    );
  }

  Future<void> checkAuth() async {
    final token = await authStorage.getAccessToken();
    if (token != null) {
      apiClient.setToken(token);
      try {
        final user = await fetchMe();
        state = AuthState(status: AuthStatus.authenticated, user: user);
        await onAuthenticated(user);
        if (shouldConnectWebSocket(user)) {
          await webSocketService.connect(token: token);
        }
      } on ForbiddenException {
        await onForbiddenProfile();
      } catch (_) {
        await webSocketService.disconnect();
        await authStorage.clearTokens();
        apiClient.setToken(null);
        state = const AuthState();
      }
    } else {
      await webSocketService.disconnect();
      state = const AuthState();
    }
  }

  Future<void> login(String email, String password) async {
    state = state.copyWith(status: AuthStatus.loading, error: null);
    try {
      final response = await apiClient.dio.post(
        loginEndpoint,
        data: {'email': email, 'password': password},
      );
      final data = response.data as Map<String, dynamic>;
      final accessToken = data['access_token'] as String;
      final refreshToken = data['refresh_token'] as String;
      final userData = data['user'] as Map<String, dynamic>;

      apiClient.setToken(accessToken);
      await authStorage.saveTokens(
        accessToken: accessToken,
        refreshToken: refreshToken,
      );

      final user = AuthUser.fromJson(userData);
      state = AuthState(status: AuthStatus.authenticated, user: user);
      await onAuthenticated(user);
      if (shouldConnectWebSocket(user)) {
        await webSocketService.connect(token: accessToken);
      }
    } on ApiException catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        error: e.message,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        error: apiErrorMessage(e, 'Login failed. Please check your credentials.'),
      );
    }
  }

  Future<void> register(
      String email, String phone, String password) async {
    state = state.copyWith(status: AuthStatus.loading, error: null);
    try {
      await apiClient.dio.post(
        registerEndpoint,
        data: {
          'email': email,
          'phone': phone,
          'password': password,
        },
      );
      await login(email, password);
    } on ApiException catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        error: e.message,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        status: AuthStatus.unauthenticated,
        error: apiErrorMessage(e, 'Registration failed. Please try again.'),
      );
    }
  }

  Future<bool> refreshToken() async {
    final storedRefresh = await authStorage.getRefreshToken();
    if (storedRefresh == null) return false;

    try {
      final response = await apiClient.dio.post(
        refreshTokenEndpoint,
        data: {'refresh_token': storedRefresh},
      );
      final data = response.data as Map<String, dynamic>;
      final newAccess = data['access_token'] as String;
      final newRefresh = data['refresh_token'] as String;

      apiClient.setToken(newAccess);
      await authStorage.saveTokens(
        accessToken: newAccess,
        refreshToken: newRefresh,
      );
      await webSocketService.connect(token: newAccess);
      return true;
    } catch (_) {
      await logout();
      return false;
    }
  }

  Future<void> logout() async {
    try {
      await webSocketService.disconnect();
      final refreshToken = await authStorage.getRefreshToken();
      if (refreshToken != null) {
        await apiClient.dio.post(
          logoutEndpoint,
          data: {'refresh_token': refreshToken},
        );
      }
    } catch (_) {
      // Silently continue — local cleanup is the priority
    }
    apiClient.setToken(null);
    await authStorage.clearTokens();
    state = const AuthState();
  }

  Future<void> setRememberedEmail(String? email) async {
    await authStorage.saveRememberedEmail(email);
  }

  Future<String?> getRememberedEmail() async {
    return await authStorage.getRememberedEmail();
  }
}