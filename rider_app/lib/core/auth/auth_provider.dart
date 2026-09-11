import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../api/endpoints.dart';
import '../network/websocket_service.dart';

export 'package:ride_hailing_shared/ride_hailing_shared.dart'
    show AuthStatus, AuthState;

final authStorageProvider = Provider<AuthStorage>((ref) => AuthStorage());

final apiClientProvider =
    Provider<ApiClient>((ref) => ApiClient(baseUrl: ApiConfig.baseUrl));

class AuthNotifier extends AppAuthController {
  AuthNotifier({
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
    final userData = data['user'] as Map<String, dynamic>?;
    return AuthUser.fromJson(userData ?? <String, dynamic>{});
  }

  @override
  Future<void> onForbiddenProfile() async {
    // A 403 on /rider/me means a bad session — clear it, like the generic
    // failure path does.
    await logout();
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final notifier = AuthNotifier(
    authStorage: ref.read(authStorageProvider),
    apiClient: ref.read(apiClientProvider),
    webSocketService: ref.read(webSocketServiceProvider),
  );
  // Install the 401 refresh callback so the API client can transparently
  // refresh and retry when the access token expires mid-session.
  ref.read(apiClientProvider).unauthorizedHandler = notifier.refreshToken;
  return notifier;
});