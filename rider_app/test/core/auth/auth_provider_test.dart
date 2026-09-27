import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/api_exceptions.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/auth/model/auth_user.dart';
import 'package:rider_app/features/home/model/rider_profile.dart';

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

  /// The real `GET /rider/me` shape: `{user, rider}`. The name and photo live
  /// on the sibling `rider` object, not the `user` one.
  Map<String, dynamic> riderMeJson() => {
        'user': {
          'id': 'user-1',
          'email': 'test@example.com',
          'phone': '+5065551234',
          'role': 'rider',
          'status': 'active',
        },
        'rider': {
          'user_id': 'user-1',
          'first_name': 'Ana',
          'last_name': 'Rojas',
          'photo_url': 'https://cdn.example.com/ana.png',
          'status': 'idle',
        },
      };

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

      test('seeds riderProfileProvider from the rider sub-object', () async {
        // The whole point of parsing both halves of `GET /rider/me`: the name
        // and photo live on `rider`, not on `user`.
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'existing-token');
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/rider/me'),
                  statusCode: 200,
                  data: riderMeJson(),
                ));

        await authNotifier.checkAuth();

        final profile = container.read(riderProfileProvider);
        expect(profile, isA<RiderProfile>());
        expect(profile?.userId, 'user-1');
        expect(profile?.firstName, 'Ana');
        expect(profile?.lastName, 'Rojas');
        expect(profile?.photoUrl, 'https://cdn.example.com/ana.png');
        expect(profile?.status, 'idle');
      });

      test('carries the rider name and photo into the session user', () async {
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'existing-token');
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/rider/me'),
                  statusCode: 200,
                  data: riderMeJson(),
                ));

        await authNotifier.checkAuth();

        final user = authNotifier.state.user;
        expect(user?.email, 'test@example.com');
        expect(user?.phone, '+5065551234');
        expect(user?.firstName, 'Ana');
        expect(user?.lastName, 'Rojas');
        expect(user?.photoUrl, 'https://cdn.example.com/ana.png');
        expect(user?.fullName, 'Ana Rojas');
      });

      test('fetchMe does not re-read /rider/me when the cache is warm',
          () async {
        // `checkAuth` runs `fetchMe` (which seeds the cache) and then
        // `onAuthenticated`. Guarding the hook keeps cold start at one GET
        // instead of the driver's two.
        when(() => mockStorage.getAccessToken())
            .thenAnswer((_) async => 'existing-token');
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/rider/me'),
                  statusCode: 200,
                  data: riderMeJson(),
                ));

        await authNotifier.checkAuth();

        verify(() => mockDio.get(ApiEndpoints.riderMe)).called(1);
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

      test('seeds riderProfileProvider through onAuthenticated', () async {
        // The login response carries only `user` (no `rider`), so the profile
        // cache is filled by the `onAuthenticated` hook reading /rider/me.
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
        when(() => mockDio.get(any()))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: '/rider/me'),
                  statusCode: 200,
                  data: riderMeJson(),
                ));

        await authNotifier.login('test@example.com', 'Password1');

        expect(container.read(riderProfileProvider)?.fullName, 'Ana Rojas');
        expect(authNotifier.state.user?.photoUrl,
            'https://cdn.example.com/ana.png');
      });

      test('a failed profile read still leaves the session authenticated',
          () async {
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 200,
          data: {
            'access_token': 'access-123',
            'refresh_token': 'refresh-123',
            'user': {'id': 'user-1', 'email': 'test@example.com'},
          },
        ));
        when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
        when(() => mockDio.get(any())).thenThrow(
            UnauthorizedException('invalid or expired token'));

        await authNotifier.login('test@example.com', 'Password1');

        expect(authNotifier.state.status, AuthStatus.authenticated);
        expect(container.read(riderProfileProvider), isNull);
      });
    });

    group('refreshProfile', () {
      test('refreshes the cached profile and the session user', () async {
        when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
            Response(
              requestOptions: RequestOptions(path: '/rider/me'),
              statusCode: 200,
              data: {
                'user': {
                  'id': 'user-1',
                  'email': 'test@example.com',
                  'phone': '+5065559999',
                },
                'rider': {
                  'user_id': 'user-1',
                  'first_name': 'Ana',
                  'last_name': 'Updated',
                  'photo_url': '',
                },
              },
            ));

        final fresh = await authNotifier.refreshProfile();

        expect(fresh?.fullName, 'Ana Updated');
        expect(container.read(riderProfileProvider)?.fullName, 'Ana Updated');
        // The `users` row is only reachable through this call — `PUT /rider/me`
        // never echoes it back.
        expect(authNotifier.state.user?.phone, '+5065559999');
      });

      test('returns null and keeps the cache when the read fails', () async {
        container.read(riderProfileProvider.notifier).state =
            const RiderProfile(userId: 'user-1', firstName: 'Ana');
        when(() => mockDio.get(ApiEndpoints.riderMe))
            .thenThrow(NotFoundException('rider not found'));

        final fresh = await authNotifier.refreshProfile();

        expect(fresh, isNull);
        expect(container.read(riderProfileProvider)?.firstName, 'Ana');
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

      test('surfaces the backend message, not Dio’s verbose text', () async {
        // Regression, found by e2e/specs/ride-offer.spec.ts: a duplicate
        // account returns 409, and the register screen rendered the raw
        // `DioException.message` — a multi-paragraph description of the
        // response status code, ending in an MDN link, on the form itself.
        // This reproduces the real shape: the error interceptor's mapped
        // `ConflictException` in `DioException.error`.
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenThrow(DioException(
          requestOptions: RequestOptions(path: '/auth/register'),
          response: Response(
            requestOptions: RequestOptions(path: '/auth/register'),
            statusCode: 409,
            data: {
              'error': {
                'code': 'CONFLICT',
                'message': 'email already registered',
              },
            },
          ),
          type: DioExceptionType.badResponse,
          error: mapStatusCodeToException(409, 'email already registered'),
          message: 'This exception was thrown because the response has a '
              'status code of 409 but the status code included in the response '
              'is not a valid status code. ...',
        ));

        await authNotifier.register(
          'existing@example.com', '+1234567890', 'Password1');

        expect(authNotifier.state.error, 'email already registered');
        expect(authNotifier.state.error, isNot(contains('This exception')));
        expect(authNotifier.state.error, isNot(contains('mozilla')));
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

      test('clears the cached rider profile', () async {
        // Without the onLoggedOut hook the previous rider's name and photo
        // stay in the container and greet the next sign-in.
        container.read(riderProfileProvider.notifier).state =
            const RiderProfile(
          userId: 'user-1',
          firstName: 'Ana',
          lastName: 'Rojas',
          photoUrl: 'https://cdn.example.com/ana.png',
        );
        when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
        when(() => mockStorage.getRefreshToken())
            .thenAnswer((_) async => null);

        await authNotifier.logout();

        expect(container.read(riderProfileProvider), isNull);
      });

      test('clears the cached rider profile even when the POST fails',
          () async {
        container.read(riderProfileProvider.notifier).state =
            const RiderProfile(userId: 'user-1', firstName: 'Ana');
        when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
        when(() => mockStorage.getRefreshToken())
            .thenAnswer((_) async => 'refresh-123');
        when(() => mockDio.post(
          any(),
          data: any(named: 'data'),
        )).thenThrow(DioException(
          requestOptions: RequestOptions(path: '/auth/logout'),
          type: DioExceptionType.connectionError,
        ));

        await authNotifier.logout();

        expect(container.read(riderProfileProvider), isNull);
        expect(authNotifier.state.status, AuthStatus.unauthenticated);
      });
    });
  });
}
