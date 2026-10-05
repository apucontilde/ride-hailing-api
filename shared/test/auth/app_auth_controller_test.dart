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

  @override
  Future<AuthUser> fetchMe() async => const AuthUser();

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
}
