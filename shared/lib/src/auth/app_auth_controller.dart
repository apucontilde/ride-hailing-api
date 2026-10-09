import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

import '../api/api_client.dart';
import '../api/api_exceptions.dart';
import '../models/auth_user.dart';
import '../network/websocket_service.dart';
import 'auth_storage.dart';

enum AuthStatus { unauthenticated, loading, authenticated }

/// Why the last [AppAuthController.refreshToken] attempt returned `false`.
///
/// [checkAuth] needs the distinction to decide whether a failed refresh after a
/// `/me` 401 is recoverable: a [transientFailure] keeps the tokens, a
/// [definitiveFailure] has already cleared them locally, [readFailed] is a
/// transient storage blip that must not wipe, and [noToken] means the access
/// token is dead with nothing to rotate.
enum _RefreshOutcome {
  success,
  noToken,
  readFailed,
  definitiveFailure,
  transientFailure,
}

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
/// ([shouldConnectWebSocket]), what a 403 from `/me` means
/// ([onForbiddenProfile]), and post-sign-out cache cleanup ([onLoggedOut]).
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

  /// Coalesces concurrent [refreshToken] callers (an explicit `checkAuth`
  /// refresh and the `ApiClient` 401 interceptor) onto one `/auth/refresh`
  /// rotation.
  Future<bool>? _refreshInFlight;
  _RefreshOutcome _lastRefreshOutcome = _RefreshOutcome.noToken;

  /// The access token currently installed in [apiClient]; kept in memory so a
  /// refresh-token-only cold start can still open the websocket even when the
  /// best-effort storage write did not land.
  String? _sessionAccessToken;

  /// Fetches the signed-in user from the app's `/me` endpoint. Throws
  /// [ApiException] (e.g. [ForbiddenException]) on failure.
  Future<AuthUser> fetchMe();

  /// Hook invoked after a successful login/refresh so subclasses can attach
  /// extra state (e.g. seed a driver profile). Default does nothing.
  Future<void> onAuthenticated(AuthUser user) async {}

  /// Hook invoked at the very end of [logout] so subclasses can drop
  /// app-level caches that are keyed to the session (e.g. a cached profile).
  /// Default does nothing.
  Future<void> onLoggedOut() async {}

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

  /// Classifies an error thrown while talking to an auth/profile endpoint.
  ///
  /// Definitive (400/401) means the server rejected the credential itself — the
  /// token is dead and cannot be recovered. Everything else (timeout, connection
  /// error, 5xx, 429, malformed body) is transient and must never destroy a
  /// session. 403 is deliberately excluded: it means the account's role is wrong
  /// for the endpoint, not that the token is invalid, and stays with
  /// [onForbiddenProfile].
  bool _isDefinitiveAuthFailure(Object error) {
    final api = switch (error) {
      ApiException() => error,
      DioException(error: final Object? mapped) when mapped is ApiException =>
        mapped,
      _ => null,
    };
    final code = api?.statusCode;
    return code == 400 || code == 401;
  }

  Future<void> checkAuth() async {
    // Storage is best-effort: a throwing read means "no token", not a crash.
    String? accessToken;
    String? storedRefreshToken;
    try {
      accessToken = await authStorage.getAccessToken();
    } catch (_) {
      accessToken = null;
    }
    try {
      storedRefreshToken = await authStorage.getRefreshToken();
    } catch (_) {
      storedRefreshToken = null;
    }

    if (accessToken == null && storedRefreshToken == null) {
      await webSocketService.disconnect();
      state = const AuthState();
      return;
    }

    if (accessToken == null) {
      // Cold start with only a refresh token: recover it before probing `/me`.
      final refreshed = await refreshToken();
      if (!refreshed) {
        // Transient (tokens kept) or definitive (already cleared locally) — the
        // session is simply unauthenticated for this launch.
        await webSocketService.disconnect();
        state = const AuthState();
        return;
      }
    } else {
      apiClient.setToken(accessToken);
      _sessionAccessToken = accessToken;
    }

    try {
      await _completeAuthentication();
    } on ForbiddenException {
      await onForbiddenProfile();
    } on UnauthorizedException {
      // The access token was rejected: refresh once (coalescing with the
      // interceptor's attempt) and retry `/me` once.
      final refreshed = await refreshToken();
      if (!refreshed) {
        await _settleFailedRefresh();
        return;
      }
      try {
        await _completeAuthentication();
      } on ForbiddenException {
        await onForbiddenProfile();
      } catch (retryError) {
        await _handleProfileFailure(retryError);
      }
    } catch (e) {
      await _handleProfileFailure(e);
    }
  }

  /// The shared success path: read `/me`, publish the session, run the
  /// subclass hook, and open the websocket when the app wants it.
  Future<void> _completeAuthentication() async {
    final user = await fetchMe();
    state = AuthState(status: AuthStatus.authenticated, user: user);
    await onAuthenticated(user);
    if (shouldConnectWebSocket(user)) {
      final token = _sessionAccessToken;
      if (token != null) {
        await webSocketService.connect(token: token);
      }
    }
  }

  /// A refresh that failed after `/me` returned 401.
  ///
  /// - transient: keep the tokens so a later launch/401 can recover.
  /// - read failed: the refresh-token read itself blipped — transient, keep the
  ///   tokens rather than wiping on a storage error.
  /// - definitive: [_doRefresh] already cleared locally.
  /// - no stored refresh token: the access token is dead with nothing to
  ///   rotate, so clear the session now.
  Future<void> _settleFailedRefresh() async {
    await webSocketService.disconnect();
    if (_lastRefreshOutcome == _RefreshOutcome.transientFailure ||
        _lastRefreshOutcome == _RefreshOutcome.readFailed ||
        _sessionAccessToken == null) {
      state = const AuthState();
      return;
    }
    await _clearLocalSession();
  }

  /// Applies the definitive/transient rule to a failed `/me` probe: only a
  /// definitive failure wipes storage; a transient one keeps the tokens and
  /// leaves a non-destructive unauthenticated state.
  Future<void> _handleProfileFailure(Object error) async {
    if (_isDefinitiveAuthFailure(error)) {
      await _clearLocalSession();
      return;
    }
    await webSocketService.disconnect();
    state = const AuthState();
  }

  /// Tears down the local session without the server revoke [logout] performs.
  /// Used only when the tokens are already dead (definitive 400/401), so a
  /// token that cannot recover is not left behind to loop.
  Future<void> _clearLocalSession() async {
    await webSocketService.disconnect();
    apiClient.setToken(null);
    _sessionAccessToken = null;
    try {
      await authStorage.clearTokens();
    } catch (_) {
      // Storage is best-effort; the in-memory token is the session of record.
    }
    state = const AuthState();
    await onLoggedOut();
  }

  /// True when the app already holds an authenticated session for an account
  /// other than [email] (or [id] when supplied). [login] refuses to overwrite
  /// such a session — callers must confirm and use [switchAccount] instead.
  ///
  /// The rule is conservative: when the current identity is *unknown* or only
  /// partially known we cannot prove it is the same account, so the caller
  /// must confirm. This matters for the driver app, whose authenticated
  /// [AuthUser] carries an id but no email, and for `onForbiddenProfile`,
  /// which yields empty id+email.
  bool needsAccountSwitch(String email, {String? id}) {
    if (state.status != AuthStatus.authenticated) return false;
    final current = state.user;
    if (current == null) return false;

    final currentId = current.id.trim();
    final currentEmail = current.email.trim().toLowerCase();
    final nextId = id?.trim() ?? '';
    final nextEmail = email.trim().toLowerCase();

    // Unknown identity — cannot prove it is the same account.
    if (currentId.isEmpty && currentEmail.isEmpty) return true;

    // Compare ids when both are known.
    if (currentId.isNotEmpty && nextId.isNotEmpty) {
      return currentId != nextId;
    }

    // Otherwise compare emails when both are known.
    if (currentEmail.isNotEmpty && nextEmail.isNotEmpty) {
      return currentEmail != nextEmail;
    }

    // Partial identity (e.g. an id but no email, the driver shape) — cannot
    // prove it is the same account.
    return true;
  }

  /// Revokes the stored refresh token through the logout endpoint and drops
  /// the local session, leaving no orphaned token behind. Same side effects as
  /// [logout]; named for the guarded switch-account path.
  Future<void> cancelCurrentSession() => logout();

  /// Cancels the current authenticated session (revoking its refresh token)
  /// before minting a new one for [email]. [login] alone never overwrites an
  /// authenticated state — this is the only path that switches accounts.
  Future<void> switchAccount(String email, String password) async {
    if (state.status == AuthStatus.authenticated) {
      await cancelCurrentSession();
    }
    await login(email, password);
  }

  Future<void> login(String email, String password) async {
    if (needsAccountSwitch(email)) {
      state = state.copyWith(
        error: 'Already signed in as ${state.user?.email}. '
            'Sign out before switching accounts.',
      );
      return;
    }
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
      _sessionAccessToken = accessToken;
      try {
        await authStorage.saveTokens(
          accessToken: accessToken,
          refreshToken: refreshToken,
        );
      } catch (_) {
        // Storage is best-effort: the in-memory token already installed above
        // is the session of record, so a failed write must not fail login.
      }

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

  /// Single-flight wrapper: concurrent callers (an explicit [checkAuth] refresh
  /// and the API client's 401 `unauthorizedHandler`) share one rotation.
  Future<bool> refreshToken() =>
      _refreshInFlight ??= _doRefresh().whenComplete(() => _refreshInFlight = null);

  Future<bool> _doRefresh() async {
    _lastRefreshOutcome = _RefreshOutcome.noToken;
    String? storedRefresh;
    try {
      storedRefresh = await authStorage.getRefreshToken();
    } catch (_) {
      // A throwing read is transient: distinguish it from a genuinely absent
      // token so [_settleFailedRefresh] keeps the session instead of wiping.
      _lastRefreshOutcome = _RefreshOutcome.readFailed;
      return false;
    }
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
      _sessionAccessToken = newAccess;
      try {
        await authStorage.saveTokens(
          accessToken: newAccess,
          refreshToken: newRefresh,
        );
      } catch (_) {
        // Storage is best-effort; the in-memory token is the session of record.
      }
      await webSocketService.connect(token: newAccess);
      _lastRefreshOutcome = _RefreshOutcome.success;
      return true;
    } catch (e) {
      // Never server-revoke here: a transient blip must not sign the user out.
      // A definitive failure clears locally so a dead token cannot loop.
      if (_isDefinitiveAuthFailure(e)) {
        _lastRefreshOutcome = _RefreshOutcome.definitiveFailure;
        await _clearLocalSession();
      } else {
        _lastRefreshOutcome = _RefreshOutcome.transientFailure;
      }
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
    _sessionAccessToken = null;
    await authStorage.clearTokens();
    state = const AuthState();
    await onLoggedOut();
  }

  Future<void> setRememberedEmail(String? email) async {
    await authStorage.saveRememberedEmail(email);
  }

  Future<String?> getRememberedEmail() async {
    return await authStorage.getRememberedEmail();
  }
}