import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/app_bootstrap.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/data/current_ride_provider.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

class MockWebSocketService extends Mock implements WebSocketService {}

void main() {
  late MockAuthStorage storage;
  late MockWebSocketService ws;
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late ProviderContainer container;
  late int riderMeCalls;
  late int currentRideCalls;
  late Map<String, dynamic> currentRidePayload;

  setUp(() {
    storage = MockAuthStorage();
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
    ws = MockWebSocketService();
    riderMeCalls = 0;
    currentRideCalls = 0;
    currentRidePayload = {
      'ride': null,
      'stops': <dynamic>[],
    };

    when(() => ws.events)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => ws.connect(token: any(named: 'token'))).thenAnswer((_) async {});
    when(() => ws.disconnect()).thenAnswer((_) async {});

    when(() => storage.getAccessToken()).thenAnswer((_) async => 'access');
    when(() => storage.getRefreshToken()).thenAnswer((_) async => 'refresh');
    when(() => storage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
    when(() => storage.clearTokens()).thenAnswer((_) async {});

    dioAdapter.onGet('/api/v1/rider/me', (server) {
      return server.replyCallback(200, (_) {
        riderMeCalls++;
        return {
          'user': {'id': 'user-1', 'email': 'rider@example.com'},
          'rider': {'user_id': 'user-1', 'first_name': 'Ana', 'status': 'idle'},
        };
      });
    });
    dioAdapter.onGet('/api/v1/rides/current', (server) {
      return server.replyCallback(200, (_) {
        currentRideCalls++;
        return Map<String, dynamic>.from(currentRidePayload);
      });
    });

    container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(storage),
        apiClientProvider.overrideWithValue(apiClient),
        webSocketServiceProvider.overrideWithValue(ws),
      ],
    );
    addTearDown(container.dispose);
  });

  test('run authenticates then restores an active ride, exactly once', () async {
    currentRidePayload = {
      'ride': {'id': 'ride-1', 'status': 'accepted'},
      'stops': <dynamic>[],
    };
    final bootstrap = container.read(sessionBootstrapProvider);
    expect(bootstrap.complete, isFalse);

    await bootstrap.run();

    expect(bootstrap.complete, isTrue);
    expect(container.read(authProvider).isAuthenticated, isTrue);
    expect(container.read(currentRideProvider).status, 'accepted');
    expect(container.read(currentRideProvider).needsRestore, isTrue);

    // Idempotent: a second run must not re-probe `/me` or `/rides/current`.
    await bootstrap.run();
    expect(riderMeCalls, 1);
    expect(currentRideCalls, 1);
  });

  test('run with no session never reads the current ride', () async {
    when(() => storage.getAccessToken()).thenAnswer((_) async => null);
    when(() => storage.getRefreshToken()).thenAnswer((_) async => null);

    final bootstrap = container.read(sessionBootstrapProvider);
    await bootstrap.run();

    expect(bootstrap.complete, isTrue);
    expect(container.read(authProvider).isAuthenticated, isFalse);
    expect(currentRideCalls, 0);
  });
}
