import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/auth/auth_storage.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/api_exceptions.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/network/websocket_service.dart';

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

  Map<String, dynamic> driverJson() => {
        'driver': {
          'user_id': 'user-1',
          'first_name': 'Jane',
          'last_name': 'Rider',
          'photo_url': null,
          'status': 'offline',
          'onboarding_status': 'documents_submitted',
          'rating_summary': '{"average":5,"count":2}',
        },
      };

  group('AuthNotifier', () {
    test('initial state is unauthenticated', () {
      expect(authNotifier.state.status, AuthStatus.unauthenticated);
      expect(authNotifier.state.user, isNull);
      expect(authNotifier.state.error, isNull);
    });

    group('checkAuth', () {
      test('sets authenticated driver state when token exists', () async {
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'existing-token');
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/driver/me'),
                  statusCode: 200,
                  data: driverJson(),
                ));

        await authNotifier.checkAuth();

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.isDriver, isTrue);
        expect(container.read(driverProfileProvider)?.firstName, 'Jane');
        verify(() => mockWebSocketService.connect(token: 'existing-token'))
            .called(1);
      });

      test('keeps a rider-role session authenticated (onboarding gate)', () async {
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'rider-token');
        when(() => mockDio.get(any()))
            .thenThrow(ForbiddenException('insufficient permissions'));

        await authNotifier.checkAuth();

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.isDriver, isFalse);
        verifyNever(() => mockWebSocketService.connect(token: any(named: 'token')));
      });

      test('clears session when driver fetch fails', () async {
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'existing-token');
        when(() => mockDio.get(any()))
            .thenThrow(UnauthorizedException('invalid or expired token'));
        when(() => mockStorage.clearTokens()).thenAnswer((_) async {});

        await authNotifier.checkAuth();

        expect(authNotifier.state.status, AuthStatus.unauthenticated);
        verify(() => mockStorage.clearTokens()).called(1);
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
      test('sets authenticated driver on successful login', () async {
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
              'role': 'driver',
            },
          },
        ));
        when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/driver/me'),
                  statusCode: 200,
                  data: driverJson(),
                ));

        await authNotifier.login('test@example.com', 'Password1');

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.isDriver, isTrue);
        expect(authNotifier.state.error, isNull);
        verify(() => mockWebSocketService.connect(token: 'access-123'))
            .called(1);
      });

      test('does not open WS for a rider-role account', () async {
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
              'role': 'rider',
            },
          },
        ));
        when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});

        await authNotifier.login('test@example.com', 'Password1');

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(authNotifier.state.isDriver, isFalse);
        verifyNever(() => mockWebSocketService.connect(token: any(named: 'token')));
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

    group('registerAsDriver', () {
      test('promotes the account and stores the driver profile', () async {
        // Register the generic promotion stub first, then the more specific
        // refresh stub so mocktail's "last match wins" resolves the call to
        // /auth/refresh rather than /driver/register.
        when(() => mockDio.post(any())).thenAnswer((_) async => Response(
              requestOptions: RequestOptions(path: '/driver/register'),
              statusCode: 201,
              data: {
                'driver': {
                  'status': 'offline',
                  'onboarding_status': 'documents_submitted',
                }
              },
            ));
        when(() => mockStorage.getRefreshToken())
            .thenAnswer((_) async => 'refresh-123');
        when(() => mockDio.post(
          ApiEndpoints.refreshToken,
          data: any(named: 'data'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/refresh'),
          statusCode: 200,
          data: {
            'access_token': 'access-new',
            'refresh_token': 'refresh-new',
            'user': {
              'id': 'user-1',
              'email': 'test@example.com',
              'role': 'driver',
            },
          },
        ));
        when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/driver/me'),
                  statusCode: 200,
                  data: driverJson(),
                ));

        final ok = await authNotifier.registerAsDriver();

        expect(ok, isTrue);
        expect(authNotifier.state.isDriver, isTrue);
        expect(container.read(driverProfileProvider)?.userId, 'user-1');
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