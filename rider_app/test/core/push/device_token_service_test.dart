import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';

import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/core/push/device_token_service.dart';
import 'package:rider_app/core/push/push_token_source.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockAuthStorage extends Mock implements AuthStorage {}

class MockWebSocketService extends Mock implements WebSocketService {}

/// A controllable [PushTokenSource] so tests can drive the token and the
/// refresh stream without any push SDK.
class FakePushTokenSource implements PushTokenSource {
  FakePushTokenSource({this.token});

  String? token;
  bool throwOnGet = false;
  final StreamController<String> refreshes =
      StreamController<String>.broadcast();

  @override
  Future<String?> getToken() async {
    if (throwOnGet) throw StateError('permission denied');
    return token;
  }

  @override
  Stream<String> get onTokenRefresh => refreshes.stream;
}

Response<dynamic> created(String path) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 201,
      data: const {'message': 'device registered'},
    );

Response<dynamic> noContent(String path) => Response<dynamic>(
      requestOptions: RequestOptions(path: path),
      statusCode: 204,
    );

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;

  setUpAll(() {
    registerFallbackValue(Options());
  });

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
  });

  DeviceTokenService buildService(
    FakePushTokenSource source, {
    DevicePlatform platform = DevicePlatform.android,
  }) {
    return DeviceTokenService(
      apiClient: mockApiClient,
      tokenSource: source,
      platform: () => platform,
    );
  }

  /// The real `GET /rider/me` shape: `{user, rider}`.
  Map<String, dynamic> riderMeJson() => {
        'user': {
          'id': 'user-1',
          'email': 'rider@example.com',
          'role': 'rider',
          'status': 'active',
        },
        'rider': {
          'user_id': 'user-1',
          'first_name': 'Ana',
          'last_name': 'Rojas',
          'status': 'idle',
        },
      };

  group('DeviceTokenService', () {
    test('register posts {token, platform} to POST /devices', () async {
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));
      final service = buildService(FakePushTokenSource(token: 'tok-123'));

      await service.register();

      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-123', 'platform': 'android'},
          )).called(1);
    });

    test('register maps the platform discriminator for ios', () async {
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));
      final service = buildService(
        FakePushTokenSource(token: 'tok-ios'),
        platform: DevicePlatform.ios,
      );

      await service.register();

      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-ios', 'platform': 'ios'},
          )).called(1);
    });

    test('no token means no server call', () async {
      final service = buildService(FakePushTokenSource(token: null));

      await service.register();

      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
    });

    test('blank token means no server call', () async {
      final service = buildService(FakePushTokenSource(token: '   '));

      await service.register();

      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
    });

    test('a token source failure is swallowed', () async {
      final source = FakePushTokenSource(token: 'tok-123')..throwOnGet = true;
      final service = buildService(source);

      await expectLater(service.register(), completes);
      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
    });

    test('a failed registration never throws', () async {
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.devices),
        response: Response(
          requestOptions: RequestOptions(path: ApiEndpoints.devices),
          statusCode: 500,
        ),
      ));
      final service = buildService(FakePushTokenSource(token: 'tok-123'));

      await expectLater(service.register(), completes);
      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).called(1);
    });

    test('a token refresh re-registers the new token', () async {
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));
      final source = FakePushTokenSource(token: 'tok-old');
      final service = buildService(source)..start();
      addTearDown(service.dispose);

      source.refreshes.add('tok-new');
      await pumpEventQueue();

      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-new', 'platform': 'android'},
          )).called(1);
    });

    test('unregister DELETEs the registered token, URL-encoded', () async {
      when(() => mockDio.post(any(), data: any(named: 'data')))
          .thenAnswer((_) async => created(ApiEndpoints.devices));
      when(() => mockDio.delete(any()))
          .thenAnswer((_) async => noContent(ApiEndpoints.devices));
      final service = buildService(FakePushTokenSource(token: 'tok/with space'));

      await service.register();
      await service.unregister();

      verify(() => mockDio.delete(
            '/api/v1/devices/tok%2Fwith%20space',
          )).called(1);
    });

    test('unregister is a no-op when nothing was registered', () async {
      final service = buildService(FakePushTokenSource(token: 'tok-123'));

      await service.unregister();

      verifyNever(() => mockDio.delete(any()));
    });

    test('unregister failures are swallowed', () async {
      when(() => mockDio.post(any(), data: any(named: 'data')))
          .thenAnswer((_) async => created(ApiEndpoints.devices));
      when(() => mockDio.delete(any())).thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.devices),
        response: Response(
          requestOptions: RequestOptions(path: ApiEndpoints.devices),
          statusCode: 500,
        ),
      ));
      final service = buildService(FakePushTokenSource(token: 'tok-123'));
      await service.register();

      await expectLater(service.unregister(), completes);
    });

    test('register() failure is non-fatal to the caller', () async {
      when(() => mockDio.post(any(), data: any(named: 'data')))
          .thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.devices),
      ));
      final service = buildService(FakePushTokenSource(token: 'tok-123'));

      await service.register();

      // The call is attempted but the exception never escapes.
      verify(() => mockDio.post(any(), data: any(named: 'data'))).called(1);
    });

    test('the raw token never reaches debugPrint', () async {
      when(() => mockDio.post(any(), data: any(named: 'data')))
          .thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.devices),
      ));
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      final service = buildService(FakePushTokenSource(token: 'secret-token'));
      await service.register();
      await service.unregister();

      expect(logs.any((line) => line.contains('secret-token')), isFalse);
    });
  });

  group('deviceTokenServiceProvider triggers', () {
    ProviderContainer buildContainer(
      FakePushTokenSource source,
      MockAuthStorage storage,
      MockWebSocketService ws,
    ) {
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          authStorageProvider.overrideWithValue(storage),
          webSocketServiceProvider.overrideWithValue(ws),
          pushTokenSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('registers after the session becomes authenticated', () async {
      final source = FakePushTokenSource(token: 'tok-123');
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));
      when(() => mockDio.post(
            ApiEndpoints.login,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.login),
            statusCode: 200,
            data: {
              'access_token': 'access-1',
              'refresh_token': 'refresh-1',
              'user': {
                'id': 'user-1',
                'email': 'rider@example.com',
                'role': 'rider',
              },
            },
          ));
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
            statusCode: 200,
            data: riderMeJson(),
          ));
      final storage = MockAuthStorage();
      when(() => storage.saveTokens(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
          )).thenAnswer((_) async {});
      final ws = MockWebSocketService();
      when(() => ws.connect(token: any(named: 'token')))
          .thenAnswer((_) async {});
      when(() => ws.disconnect()).thenAnswer((_) async {});

      final container = buildContainer(source, storage, ws);
      container.read(deviceTokenServiceProvider);

      await container
          .read(authProvider.notifier)
          .login('rider@example.com', 'Password1');
      await pumpEventQueue();

      expect(container.read(authProvider).isAuthenticated, isTrue);
      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-123', 'platform': 'android'},
          )).called(1);
    });

    test('a registration failure leaves the session authenticated', () async {
      final source = FakePushTokenSource(token: 'tok-123');
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.devices),
        response: Response(
          requestOptions: RequestOptions(path: ApiEndpoints.devices),
          statusCode: 500,
        ),
      ));
      when(() => mockDio.post(
            ApiEndpoints.login,
            data: any(named: 'data'),
          )).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.login),
            statusCode: 200,
            data: {
              'access_token': 'access-1',
              'refresh_token': 'refresh-1',
              'user': {
                'id': 'user-1',
                'email': 'rider@example.com',
                'role': 'rider',
              },
            },
          ));
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
            statusCode: 200,
            data: riderMeJson(),
          ));
      final storage = MockAuthStorage();
      when(() => storage.saveTokens(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
          )).thenAnswer((_) async {});
      final ws = MockWebSocketService();
      when(() => ws.connect(token: any(named: 'token')))
          .thenAnswer((_) async {});
      when(() => ws.disconnect()).thenAnswer((_) async {});

      final container = buildContainer(source, storage, ws);
      container.read(deviceTokenServiceProvider);

      await container
          .read(authProvider.notifier)
          .login('rider@example.com', 'Password1');
      await pumpEventQueue();

      expect(container.read(authProvider).isAuthenticated, isTrue);
      expect(container.read(authProvider).error, isNull);
    });

    test('sign-out unregisters the token before tokens are cleared', () async {
      final source = FakePushTokenSource(token: 'tok-123');
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));
      when(() => mockDio.delete(any()))
          .thenAnswer((_) async => noContent(ApiEndpoints.devices));
      final storage = MockAuthStorage();
      when(() => storage.getRefreshToken()).thenAnswer((_) async => null);
      when(() => storage.clearTokens()).thenAnswer((_) async {});
      final ws = MockWebSocketService();
      when(() => ws.disconnect()).thenAnswer((_) async {});

      final container = buildContainer(source, storage, ws);
      // Register the token first so sign-out has something to unregister.
      await container.read(deviceTokenServiceProvider).register();

      await container.read(authProvider.notifier).logout();

      // The DELETE must fire while the bearer is still installed, i.e. before
      // `super.logout()` clears local tokens (a later call would 401).
      verifyInOrder([
        () => mockDio.delete('/api/v1/devices/tok-123'),
        () => storage.clearTokens(),
      ]);
      expect(container.read(authProvider).status, AuthStatus.unauthenticated);
    });
  });
}
