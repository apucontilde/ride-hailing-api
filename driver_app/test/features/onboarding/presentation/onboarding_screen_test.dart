import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/auth/auth_storage.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/features/onboarding/presentation/onboarding_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}
class MockWebSocketService extends Mock implements WebSocketService {}

/// US-D1: the names the onboarding form collects must reach the server before
/// the driver is sent to `/home`. Before this call the account was promoted but
/// its name stayed empty until a manual profile edit.
void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late MockWebSocketService mockWebSocketService;

  Map<String, dynamic> driverJson({
    String firstName = 'Jane',
    String lastName = 'Rider',
  }) =>
      {
        'driver': {
          'user_id': 'user-1',
          'first_name': firstName,
          'last_name': lastName,
          'photo_url': null,
          'status': 'offline',
          'onboarding_status': 'documents_submitted',
          'rating_summary': '',
        },
      };

  setUp(() {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockWebSocketService = MockWebSocketService();

    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockStorage.getRefreshToken())
        .thenAnswer((_) async => 'refresh-123');
    when(() => mockStorage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});

    // POST /driver/register, then the token rotation and the profile probe.
    when(() => mockDio.post(ApiEndpoints.driverRegister)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverRegister),
        statusCode: 201,
        data: {'driver': {'status': 'offline'}},
      ),
    );
    when(() => mockDio.post(
          ApiEndpoints.refreshToken,
          data: any(named: 'data'),
        )).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.refreshToken),
        statusCode: 200,
        data: {
          'access_token': 'access-new',
          'refresh_token': 'refresh-new',
          'user': {'id': 'user-1', 'email': 'a@b.c', 'role': 'driver'},
        },
      ),
    );
    when(() => mockDio.get(ApiEndpoints.driverMe)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
        statusCode: 200,
        data: driverJson(),
      ),
    );
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
        statusCode: 200,
        data: driverJson(firstName: 'Ava', lastName: 'Lopez'),
      ),
    );
  });

  Future<void> pumpOnboarding(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/onboarding',
      routes: [
        GoRoute(
          path: '/onboarding',
          builder: (_, _) => const OnboardingScreen(),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home Screen')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('registration persists the collected names via PUT /driver/me',
      (tester) async {
    await pumpOnboarding(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'First name'),
      'Ava',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Last name'),
      'Lopez',
    );
    await tester.tap(find.text('Register as a driver'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockDio.put(ApiEndpoints.driverMe, data: captureAny(named: 'data')),
    ).captured;
    expect(captured.single, {'first_name': 'Ava', 'last_name': 'Lopez'});

    expect(find.text('Home Screen'), findsOneWidget);
  });

  testWidgets('a failed name save still lands the driver on /home',
      (tester) async {
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenThrow(
      DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
        message: 'offline',
      ),
    );

    await pumpOnboarding(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'First name'),
      'Ava',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Last name'),
      'Lopez',
    );
    await tester.tap(find.text('Register as a driver'));
    await tester.pumpAndSettle();

    verify(
      () => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')),
    ).called(1);
    expect(find.text('Home Screen'), findsOneWidget);
  });
}
