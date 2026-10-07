import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';

import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/auth/auth_storage.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/push/device_token_service.dart';
import 'package:driver_app/core/push/push_token_source.dart';
import 'package:driver_app/features/home/providers/availability_notifier.dart';

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

  Map<String, dynamic> driverJson() => {
        'driver': {
          'user_id': 'user-1',
          'first_name': 'Jane',
          'status': 'offline',
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
      when(() => mockDio.delete(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.devices),
            statusCode: 204,
          ));
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
                'email': 'driver@example.com',
                'role': 'driver',
              },
            },
          ));
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
            statusCode: 200,
            data: driverJson(),
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

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          authStorageProvider.overrideWithValue(storage),
          webSocketServiceProvider.overrideWithValue(ws),
          pushTokenSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceTokenServiceProvider);

      await container
          .read(authProvider.notifier)
          .login('driver@example.com', 'Password1');
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
                'email': 'driver@example.com',
                'role': 'driver',
              },
            },
          ));
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
            statusCode: 200,
            data: driverJson(),
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

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          authStorageProvider.overrideWithValue(storage),
          webSocketServiceProvider.overrideWithValue(ws),
          pushTokenSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceTokenServiceProvider);

      await container
          .read(authProvider.notifier)
          .login('driver@example.com', 'Password1');
      await pumpEventQueue();

      expect(container.read(authProvider).isAuthenticated, isTrue);
      expect(container.read(authProvider).error, isNull);
    });

    test('registers when availability becomes online', () async {
      final source = FakePushTokenSource(token: 'tok-123');
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          pushTokenSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);
      container.read(deviceTokenServiceProvider);

      container.read(availabilityProvider.notifier).setOnline();
      await pumpEventQueue();

      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-123', 'platform': 'android'},
          )).called(1);
    });

    test(
        'login registers and logout unregisters through the real provider graph',
        () async {
      // This is the regression guard for the Riverpod dependency cycle: the
      // service provider and the auth provider are BOTH real (no
      // `deviceTokenServiceProvider.overrideWithValue(fake)`), so the provider
      // edges are actually resolved. Before the fix the service provider added
      // a `ref.listen(authProvider)` edge while `AuthNotifier.logout()` read
      // the service back, so materializing this graph and logging out was the
      // shape that had to stay cycle-free.
      final source = FakePushTokenSource(token: 'tok-123');
      when(() => mockDio.post(
            ApiEndpoints.devices,
            data: any(named: 'data'),
          )).thenAnswer((_) async => created(ApiEndpoints.devices));
      when(() => mockDio.delete(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.devices),
            statusCode: 204,
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
                'email': 'driver@example.com',
                'role': 'driver',
              },
            },
          ));
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
            statusCode: 200,
            data: driverJson(),
          ));
      final storage = MockAuthStorage();
      when(() => storage.saveTokens(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
          )).thenAnswer((_) async {});
      when(() => storage.getAccessToken()).thenAnswer((_) async => null);
      when(() => storage.getRefreshToken()).thenAnswer((_) async => null);
      when(() => storage.clearTokens()).thenAnswer((_) async {});
      final ws = MockWebSocketService();
      when(() => ws.connect(token: any(named: 'token')))
          .thenAnswer((_) async {});
      when(() => ws.disconnect()).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          authStorageProvider.overrideWithValue(storage),
          webSocketServiceProvider.overrideWithValue(ws),
          pushTokenSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);

      // Materialize the real service provider too.
      container.read(deviceTokenServiceProvider);

      await container
          .read(authProvider.notifier)
          .login('driver@example.com', 'Password1');
      await pumpEventQueue();

      expect(container.read(authProvider).isAuthenticated, isTrue);
      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-123', 'platform': 'android'},
          )).called(1);

      await container.read(authProvider.notifier).logout();
      await pumpEventQueue();

      expect(container.read(authProvider).isAuthenticated, isFalse);
      verify(() => mockDio.delete(
            ApiEndpoints.deviceUnregister('tok-123'),
          )).called(1);
    });

    test(
        'an authenticated transition registers even if the service was never '
        'materialized first', () async {
      // Before the fix the ONLY auth trigger was a `ref.listen(authProvider)`
      // edge INSIDE the service provider, so login registered nothing unless
      // something had already read `deviceTokenServiceProvider` (as app.dart
      // does). The one-directional fix moves the trigger into the auth hook,
      // which reads the service, so login alone registers it.
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
                'email': 'driver@example.com',
                'role': 'driver',
              },
            },
          ));
      when(() => mockDio.get(any())).thenAnswer((_) async => Response(
            requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
            statusCode: 200,
            data: driverJson(),
          ));
      final storage = MockAuthStorage();
      when(() => storage.saveTokens(
            accessToken: any(named: 'accessToken'),
            refreshToken: any(named: 'refreshToken'),
          )).thenAnswer((_) async {});
      when(() => storage.getAccessToken()).thenAnswer((_) async => null);
      when(() => storage.getRefreshToken()).thenAnswer((_) async => null);
      when(() => storage.clearTokens()).thenAnswer((_) async {});
      final ws = MockWebSocketService();
      when(() => ws.connect(token: any(named: 'token')))
          .thenAnswer((_) async {});
      when(() => ws.disconnect()).thenAnswer((_) async {});

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          authStorageProvider.overrideWithValue(storage),
          webSocketServiceProvider.overrideWithValue(ws),
          pushTokenSourceProvider.overrideWithValue(source),
        ],
      );
      addTearDown(container.dispose);

      // Deliberately NO `container.read(deviceTokenServiceProvider)` here.
      await container
          .read(authProvider.notifier)
          .login('driver@example.com', 'Password1');
      await pumpEventQueue();

      verify(() => mockDio.post(
            ApiEndpoints.devices,
            data: {'token': 'tok-123', 'platform': 'android'},
          )).called(1);
    });
  });
}
