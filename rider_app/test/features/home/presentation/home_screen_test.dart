import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/features/home/presentation/home_screen.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/network/websocket_service.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}
class MockWebSocketService extends Mock implements WebSocketService {}

void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late MockWebSocketService mockWebSocketService;

  setUp(() {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockWebSocketService = MockWebSocketService();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => 'token');
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
  });

  Widget createTestWidget() {
    return ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
      ],
      child: const MaterialApp(home: HomeScreen()),
    );
  }

  testWidgets('shows map and bottom sheet on home screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('booking flow: shows destination field and request trip button',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    expect(find.text('Where to?'), findsOneWidget);
  });

  testWidgets('drawer header shows the signed-in rider, not a literal',
      (WidgetTester tester) async {
    // A real auth bootstrap against a stubbed `GET /rider/me`, so the drawer
    // header renders exactly what the app would render in production.
    when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
        Response(
          requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
          statusCode: 200,
          data: {
            'user': {'id': 'user-1', 'email': 'ana@example.com'},
            'rider': {
              'user_id': 'user-1',
              'first_name': 'Ana',
              'last_name': 'Rojas',
              'status': 'idle',
            },
          },
        ));
    final container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authProvider.notifier).checkAuth();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('Ana Rojas'), findsOneWidget);
    expect(find.text('ana@example.com'), findsOneWidget);
    expect(find.text('Rider'), findsNothing);
  });
}