import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/api_exceptions.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/auth/model/auth_user.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}
class MockWebSocketService extends Mock implements WebSocketService {}

void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late MockWebSocketService mockWebSocketService;
  late ProviderContainer container;
  late AuthNotifier authNotifier;

  setUp(() {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockWebSocketService = MockWebSocketService();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    addTearDown(container.dispose);
    authNotifier = container.read(authProvider.notifier);
  });

  group('AuthNotifier', () {
    test('initial state is unauthenticated', () {
      expect(authNotifier.state.status, AuthStatus.unauthenticated);
      expect(authNotifier.state.user, isNull);
      expect(authNotifier.state.error, isNull);
    });

    group('checkAuth', () {
      test('sets authenticated state when token exists', () async {
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'existing-token');
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: '/auth/me'),
                statusCode: 200,
                data: {'user': {'id': 'user-1', 'email': 'test@example.com'}},
              ));

        await authNotifier.checkAuth();

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.user, isA<AuthUser>());
      });

      test('stays unauthenticated when no token exists', () async {
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => null);

        await authNotifier.checkAuth();

        expect(authNotifier.state.status, AuthStatus.unauthenticated);
        expect(authNotifier.state.user, isNull);
      });
    });

    group('login', () {
      test('sets loading then authenticated on successful login', () async {
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 200,
          data: {
            'access_token': 'access-123',
            'refresh_token': 'refresh-123',
            'user': {
              'id': 'user-1',
              'email': 'test@example.com',
            },
          },
        ));
        when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});

        final future = authNotifier.login('test@example.com', 'Password1');

        expect(authNotifier.state.status, AuthStatus.loading);

        await future;

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.user?.email, 'test@example.com');
        expect(authNotifier.state.error, isNull);
      });

      test('sets error on failed login', () async {
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenThrow(DioException(
          requestOptions: RequestOptions(path: '/auth/login'),
          response: Response(
            requestOptions: RequestOptions(path: '/auth/login'),
            statusCode: 401,
            data: {'message': 'Invalid credentials'},
          ),
        ));

        await authNotifier.login('test@example.com', 'wrong');

        expect(authNotifier.state.status, AuthStatus.unauthenticated);
        expect(authNotifier.state.error, isNotNull);
      });
    });

    group('register', () {
      test('sets loading then authenticated on successful registration', () async {
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/register'),
          statusCode: 201,
          data: {
            'access_token': 'access-123',
            'refresh_token': 'refresh-123',
            'user': {
              'id': 'user-1',
              'email': 'new@example.com',
              'phone': '+1234567890',
            },
          },
        ));
        when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
        // Mocking the login call that happens after successful registration
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 200,
          data: {
            'access_token': 'access-123',
            'refresh_token': 'refresh-123',
            'user': {
              'id': 'user-1',
              'email': 'new@example.com',
              'phone': '+1234567890',
            },
          },
        ));

        final future = authNotifier.register(
          'new@example.com', '+1234567890', 'Password1');

        expect(authNotifier.state.status, AuthStatus.loading);

        await future;

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.user?.email, 'new@example.com');
        expect(authNotifier.state.user?.phone, '+1234567890');
        expect(authNotifier.state.error, isNull);
      });

      test('sets error on failed registration', () async {
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenThrow(ConflictException('Email already registered'));

        await authNotifier.register(
          'existing@example.com', '+1234567890', 'Password1');

        expect(authNotifier.state.status, AuthStatus.unauthenticated);
        expect(authNotifier.state.error, contains('already registered'));
      });
    });

    group('logout', () {
      test('clears tokens and sets unauthenticated', () async {
        when(() => mockStorage.clearTokens())
            .thenAnswer((_) async {});
        when(() => mockStorage.getRefreshToken())
            .thenAnswer((_) async => 'refresh-123');
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/logout'),
          statusCode: 200,
          data: {},
        ));

        await authNotifier.logout();

        expect(authNotifier.state.status, AuthStatus.unauthenticated);
        expect(authNotifier.state.user, isNull);
        verify(() => mockStorage.clearTokens()).called(1);
      });
    });
  });
}
