import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:go_router/go_router.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/api_exceptions.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/auth/presentation/login_screen.dart';

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
    when(() => mockStorage.saveTokens(
      accessToken: any(named: 'accessToken'),
      refreshToken: any(named: 'refreshToken'),
    )).thenAnswer((_) async {});
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => null);
    when(() => mockStorage.getRememberedEmail()).thenAnswer((_) async => null);
    when(() => mockStorage.saveRememberedEmail(any())).thenAnswer((_) async {});
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
  });

  Widget createApp() {
    return ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/login',
          routes: [
            GoRoute(
              path: '/login',
              builder: (context, state) => const LoginScreen(),
            ),
            GoRoute(
              path: '/home',
              builder: (context, state) => const Scaffold(
                body: Text('Home'),
              ),
            ),
            GoRoute(
              path: '/register',
              builder: (context, state) => const Scaffold(
                body: Text('Register'),
              ),
            ),
            GoRoute(
              path: '/forgot-password',
              builder: (context, state) => const Scaffold(
                body: Text('Forgot Password'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('renders email and password fields', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Log In'), findsOneWidget);
  });

  testWidgets('shows validation errors for empty fields',
      (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pump();

    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
  });

  testWidgets('shows error on failed login', (WidgetTester tester) async {
    when(() => mockDio.post(
      any(),
      data: any(named: 'data'),
    )).thenThrow(ApiException('Invalid credentials', statusCode: 401));

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), 'test@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid credentials'), findsOneWidget);
  });

  testWidgets('shows loading state while logging in',
      (WidgetTester tester) async {
    final completer = Completer<Response>();
    when(() => mockDio.post(
      any(),
      data: any(named: 'data'),
    )).thenAnswer((_) => completer.future);

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), 'test@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );

    completer.complete(Response(
      requestOptions: RequestOptions(path: '/auth/login'),
      statusCode: 200,
      data: {
        'access_token': 'token',
        'refresh_token': 'refresh',
        'user': {'id': '1', 'email': 'test@test.com'},
      },
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('navigates to register screen', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.text("Don't have an account? Sign up"));
    await tester.pumpAndSettle();

    expect(find.text('Register'), findsOneWidget);
  });

  testWidgets('navigates to forgot password screen',
      (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot Password'), findsOneWidget);
  });
}
