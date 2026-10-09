import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockWebSocketService extends Mock implements WebSocketService {}

class TestAuthController extends AppAuthController {
  TestAuthController({
    required super.authStorage,
    required super.apiClient,
    required super.webSocketService,
  }) : super(
          loginEndpoint: '/api/v1/auth/login',
          registerEndpoint: '/api/v1/auth/register',
          refreshTokenEndpoint: '/api/v1/auth/refresh',
          logoutEndpoint: '/api/v1/auth/logout',
        );

  /// Overridable `/me` result so a test can drive transient/definitive
  /// failures (a 401 → refresh flow, a 500, a connection error).
  Future<AuthUser> Function()? meHandler;

  /// Counts [onLoggedOut] invocations so a test can assert the teardown hook
  /// fires exactly once.
  int loggedOutCalls = 0;

  @override
  Future<AuthUser> fetchMe() =>
      meHandler?.call() ?? Future<AuthUser>.value(const AuthUser());

  @override
  Future<void> onLoggedOut() async {
    loggedOutCalls++;
  }

  void authenticate(AuthUser user) {
    state = AuthState(status: AuthStatus.authenticated, user: user);
  }
}

void main() {
  late MockAuthStorage storage;
  late MockApiClient apiClient;
  late MockDio dio;
  late MockWebSocketService webSocketService;
  late TestAuthController controller;

  setUp(() {
    storage = MockAuthStorage();
    apiClient = MockApiClient();
    dio = MockDio();
    webSocketService = MockWebSocketService();
    when(() => apiClient.dio).thenReturn(dio);
    when(() => webSocketService.disconnect()).thenAnswer((_) async {});
    when(() => webSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => storage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
    when(() => storage.clearTokens()).thenAnswer((_) async {});
    when(() => storage.getRefreshToken()).thenAnswer((_) async => 'refresh-old');
    controller = TestAuthController(
      authStorage: storage,
      apiClient: apiClient,
      webSocketService: webSocketService,
    );
  });

  group('needsAccountSwitch', () {
    test('is false while unauthenticated', () {
      expect(controller.needsAccountSwitch('any@test.com'), isFalse);
    });

    test('is false for the same email regardless of case or whitespace', () {
      controller.authenticate(
        const AuthUser(id: 'u1', email: 'Current@Test.com'),
      );

      expect(controller.needsAccountSwitch('  current@test.com '), isFalse);
    });

    test('is true for a different email', () {
      controller.authenticate(
        const AuthUser(id: 'u1', email: 'current@test.com'),
      );

      expect(controller.needsAccountSwitch('other@test.com'), isTrue);
    });

    test('compares the id when one is supplied', () {
      controller.authenticate(
        const AuthUser(id: 'u1', email: 'same@test.com'),
      );

      expect(controller.needsAccountSwitch('same@test.com', id: 'u1'), isFalse);
      expect(controller.needsAccountSwitch('same@test.com', id: 'u2'), isTrue);
    });

    test('is true when the current identity is completely unknown', () {
      // `onForbiddenProfile` yields an authenticated user with empty id+email.
      controller.authenticate(const AuthUser());

      expect(controller.needsAccountSwitch('other@x.com'), isTrue);
    });

    test('is true when only the id is known (driver shape, no email)', () {
      // The driver app's authenticated AuthUser has an id but no email.
      controller.authenticate(const AuthUser(id: 'driver-1', role: 'driver'));

      expect(controller.needsAccountSwitch('other@x.com'), isTrue);
    });

    test('is false when the same id is supplied for the driver shape', () {
      controller.authenticate(const AuthUser(id: 'driver-1', role: 'driver'));

      expect(
        controller.needsAccountSwitch('other@x.com', id: 'driver-1'),
        isFalse,
      );
    });
  });

  group('login guard', () {
    test('refuses to overwrite an authenticated session for another account',
        () async {
      controller.authenticate(
        const AuthUser(id: 'u1', email: 'current@test.com'),
      );

      await controller.login('other@test.com', 'pw');

      expect(controller.state.isAuthenticated, isTrue);
      expect(controller.state.user?.email, 'current@test.com');
      expect(controller.state.error, isNotNull);
      verifyNever(() => dio.post(any(), data: any(named: 'data')));
    });

    test('refuses to overwrite an authenticated empty-identity session',
        () async {
      controller.authenticate(const AuthUser());

      await controller.login('other@x.com', 'pw');

      expect(controller.state.isAuthenticated, isTrue);
      expect(controller.state.user?.id, '');
      expect(controller.state.error, isNotNull);
      verifyNever(() => dio.post(any(), data: any(named: 'data')));
    });

    test('refuses to overwrite an authenticated driver-shape session',
        () async {
      controller.authenticate(const AuthUser(id: 'driver-1', role: 'driver'));

      await controller.login('other@x.com', 'pw');

      expect(controller.state.isAuthenticated, isTrue);
      expect(controller.state.user?.id, 'driver-1');
      expect(controller.state.error, isNotNull);
      verifyNever(() => dio.post(any(), data: any(named: 'data')));
    });

    test('allows a normal login while unauthenticated', () async {
      when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/login'),
          statusCode: 200,
          data: {
            'access_token': 'access',
            'refresh_token': 'refresh',
            'user': {'id': 'u1', 'email': 'current@test.com'},
          },
        ),
      );

      await controller.login('current@test.com', 'pw');

      expect(controller.state.isAuthenticated, isTrue);
      expect(controller.state.user?.email, 'current@test.com');
    });
  });

  group('cancelCurrentSession', () {
    test('revokes the stored refresh token and clears the session', () async {
      controller.authenticate(
        const AuthUser(id: 'u1', email: 'current@test.com'),
      );
      when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/logout'),
          statusCode: 200,
        ),
      );

      await controller.cancelCurrentSession();

      verify(() => dio.post(
            '/api/v1/auth/logout',
            data: {'refresh_token': 'refresh-old'},
          )).called(1);
      verify(() => storage.clearTokens()).called(1);
      expect(controller.state.isAuthenticated, isFalse);
    });
  });

  group('switchAccount', () {
    test('revokes the prior session before minting the new one', () async {
      controller.authenticate(
        const AuthUser(id: 'u1', email: 'current@test.com'),
      );
      final calls = <String>[];
      when(() => dio.post(any(), data: any(named: 'data'))).thenAnswer(
        (invocation) async {
          final path = invocation.positionalArguments.first as String;
          calls.add(path);
          if (path.contains('logout')) {
            return Response(
              requestOptions: RequestOptions(path: path),
              statusCode: 200,
            );
          }
          return Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
              'user': {'id': 'u2', 'email': 'other@test.com'},
            },
          );
        },
      );

      await controller.switchAccount('other@test.com', 'pw');

      expect(calls.first, '/api/v1/auth/logout');
      expect(calls.last, '/api/v1/auth/login');
      expect(controller.state.isAuthenticated, isTrue);
      expect(controller.state.user?.email, 'other@test.com');
    });
  });

  group('checkAuth — session recovery', () {
    test('recovers a refresh-token-only cold start without clearing',
        () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => null);
      when(() => storage.getRefreshToken()).thenAnswer((_) async => 'refresh-r');
      when(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
            statusCode: 200,
            data: {
              'access_token': 'access-new',
              'refresh_token': 'refresh-new',
            },
          ));

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isTrue);
      verify(() => storage.saveTokens(
            accessToken: 'access-new',
            refreshToken: 'refresh-new',
          )).called(1);
      verifyNever(() => storage.clearTokens());
    });

    test('keeps tokens when /me fails with a 500', () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'access');
      controller.meHandler = () async => throw ServerException('boom');

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isFalse);
      verifyNever(() => storage.clearTokens());
    });

    test('keeps tokens when /me fails with a network error', () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'access');
      controller.meHandler = () async => throw DioException(
            requestOptions: RequestOptions(path: '/rider/me'),
            type: DioExceptionType.connectionTimeout,
          );

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isFalse);
      verifyNever(() => storage.clearTokens());
    });

    test('/me 401 refreshes once and retries', () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'stale');
      when(() => storage.getRefreshToken())
          .thenAnswer((_) async => 'refresh-r');
      when(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
            statusCode: 200,
            data: {
              'access_token': 'access-new',
              'refresh_token': 'refresh-new',
            },
          ));
      var meCalls = 0;
      controller.meHandler = () async {
        meCalls++;
        if (meCalls == 1) throw UnauthorizedException('expired');
        return const AuthUser(id: 'u1', email: 'a@b.com');
      };

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isTrue);
      expect(meCalls, 2);
      verify(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).called(1);
      verifyNever(() => storage.clearTokens());
    });

    test('clears a dead access token when /me 401 and no refresh token exists',
        () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'stale');
      when(() => storage.getRefreshToken()).thenAnswer((_) async => null);
      controller.meHandler = () async => throw UnauthorizedException('expired');

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isFalse);
      verify(() => storage.clearTokens()).called(1);
    });

    test('keeps tokens when /me 401 and the refresh-token read throws',
        () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'stale');
      when(() => storage.getRefreshToken())
          .thenAnswer((_) async => throw Exception('storage read blip'));
      controller.meHandler = () async => throw UnauthorizedException('expired');

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isFalse);
      verifyNever(() => storage.clearTokens());
      verifyNever(() => dio.post(
            '/api/v1/auth/logout',
            data: any(named: 'data'),
          ));
    });

    test('fires onLoggedOut exactly once when the session is definitively dead',
        () async {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'stale');
      when(() => storage.getRefreshToken())
          .thenAnswer((_) async => 'refresh-r');
      when(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
        error: mapStatusCodeToException(401, 'bad token'),
      ));
      controller.meHandler = () async => throw UnauthorizedException('expired');

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isFalse);
      expect(controller.loggedOutCalls, 1);
    });
  });

  group('refreshToken — single-flight and failure handling', () {
    test('coalesces concurrent refresh callers', () async {
      when(() => storage.getRefreshToken())
          .thenAnswer((_) async => 'refresh-r');
      final completer = Completer<Response>();
      when(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).thenAnswer((_) => completer.future);

      final first = controller.refreshToken();
      final second = controller.refreshToken();

      completer.complete(Response(
        requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
        statusCode: 200,
        data: {'access_token': 'a', 'refresh_token': 'r'},
      ));

      expect(await first, isTrue);
      expect(await second, isTrue);
      verify(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).called(1);
    });

    test('a transient failure keeps tokens and never revokes', () async {
      when(() => storage.getRefreshToken())
          .thenAnswer((_) async => 'refresh-r');
      when(() => dio.post(
            '/api/v1/auth/refresh',
            data: {'refresh_token': 'refresh-r'},
          )).thenThrow(DioException(
            requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
            type: DioExceptionType.connectionError,
          ));

      final ok = await controller.refreshToken();

      expect(ok, isFalse);
      verifyNever(() => dio.post(
            '/api/v1/auth/logout',
            data: any(named: 'data'),
          ));
      verifyNever(() => storage.clearTokens());
    });

    for (final code in [401, 400]) {
      test('a definitive $code failure clears locally without revoking',
          () async {
        when(() => storage.getRefreshToken())
            .thenAnswer((_) async => 'refresh-r');
        when(() => dio.post(
              '/api/v1/auth/refresh',
              data: {'refresh_token': 'refresh-r'},
            )).thenThrow(DioException(
              requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
              response: Response(
                requestOptions: RequestOptions(path: '/api/v1/auth/refresh'),
                statusCode: code,
              ),
              type: DioExceptionType.badResponse,
              error: mapStatusCodeToException(code, 'bad token'),
            ));

        final ok = await controller.refreshToken();

        expect(ok, isFalse);
        verify(() => storage.clearTokens()).called(1);
        verifyNever(() => dio.post(
              '/api/v1/auth/logout',
              data: any(named: 'data'),
            ));
      });
    }
  });

  group('storage failures', () {
    test('login authenticates even when saving tokens throws', () async {
      when(() => storage.saveTokens(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
          )).thenAnswer((_) async => throw Exception('storage down'));
      when(() => dio.post(
            '/api/v1/auth/login',
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: '/api/v1/auth/login'),
            statusCode: 200,
            data: {
              'access_token': 'access',
              'refresh_token': 'refresh',
              'user': {'id': 'u1', 'email': 'a@b.com'},
            },
          ));

      await controller.login('a@b.com', 'pw');

      expect(controller.state.isAuthenticated, isTrue);
      expect(controller.state.error, isNull);
    });

    test('a throwing token read is treated as absent', () async {
      when(() => storage.getAccessToken())
          .thenAnswer((_) async => throw Exception('read failed'));
      when(() => storage.getRefreshToken())
          .thenAnswer((_) async => throw Exception('read failed'));

      await controller.checkAuth();

      expect(controller.state.isAuthenticated, isFalse);

      final ok = await controller.refreshToken();
      expect(ok, isFalse);
    });
  });
}
