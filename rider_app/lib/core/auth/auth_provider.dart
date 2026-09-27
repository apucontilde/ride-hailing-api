import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../api/endpoints.dart';
import '../network/websocket_service.dart';
import '../../features/home/model/rider_profile.dart';

export 'package:ride_hailing_shared/ride_hailing_shared.dart'
    show AuthStatus, AuthState;

final authStorageProvider = Provider<AuthStorage>((ref) => AuthStorage());

final apiClientProvider =
    Provider<ApiClient>((ref) => ApiClient(baseUrl: ApiConfig.baseUrl));

/// The live rider profile from `GET /rider/me`, maintained by [AuthNotifier].
///
/// Mirrors the driver's `driverProfileProvider`; `/profile` and the home drawer
/// header read it instead of hardcoding a name.
final riderProfileProvider = StateProvider<RiderProfile?>((ref) => null);

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
  Future<AuthUser> fetchMe() async {
    final response = await apiClient.dio.get(ApiEndpoints.riderMe);
    final data = response.data as Map<String, dynamic>;
    return _parseProfile(data);
  }

  @override
  Future<void> onAuthenticated(AuthUser user) async {
    // `checkAuth` runs `fetchMe` (which already seeds the cache) immediately
    // before this hook, so only the login / token-rotation path has anything
    // to fetch. Non-fatal — /profile surfaces its own error state.
    if (_ref.read(riderProfileProvider) != null) return;
    await refreshProfile();
  }

  @override
  Future<void> onLoggedOut() async {
    // Without this the previous rider's name/photo stay in the container and
    // greet the next sign-in.
    _ref.read(riderProfileProvider.notifier).state = null;
  }

  @override
  Future<void> onForbiddenProfile() async {
    // A 403 on /rider/me means a bad session — clear it, like the generic
    // failure path does.
    await logout();
  }

  /// Re-reads `GET /rider/me` and refreshes both the profile cache and the
  /// session's [AuthUser] (the `users` row owns email/phone, the `riders` row
  /// owns name/photo, and only this call returns both).
  ///
  /// Returns the fresh profile, or `null` when the read failed — the caller
  /// keeps whatever it already had.
  Future<RiderProfile?> refreshProfile() async {
    RiderProfile? profile;
    try {
      final response = await apiClient.dio.get(ApiEndpoints.riderMe);
      final data = response.data as Map<String, dynamic>;
      state = state.copyWith(user: _parseProfile(data));
      profile = _ref.read(riderProfileProvider);
    } catch (_) {
      // Non-fatal — keep current session state.
      return null;
    }
    return profile;
  }

  /// `GET /rider/me` answers `{user, rider}`. The name and photo live on the
  /// sibling `rider` object, which the shared [AuthUser.fromJson] folds in and
  /// which also seeds [riderProfileProvider].
  AuthUser _parseProfile(Map<String, dynamic> data) {
    final rider = data['rider'] as Map<String, dynamic>?;
    if (rider != null) _setProfile(RiderProfile.fromJson(rider));
    return AuthUser.fromJson(
      data['user'] as Map<String, dynamic>? ?? const <String, dynamic>{},
      rider: rider,
    );
  }

  void _setProfile(RiderProfile rider) {
    _ref.read(riderProfileProvider.notifier).state = rider;
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
