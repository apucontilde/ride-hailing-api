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
import 'package:rider_app/features/auth/presentation/forgot_password_screen.dart';

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
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => null);
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
  });

  Widget createTestWidget() {
    return ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/forgot-password',
          routes: [
            GoRoute(
              path: '/forgot-password',
              builder: (context, state) => const ForgotPasswordScreen(),
            ),
            GoRoute(
              path: '/login',
              builder: (context, state) => const Scaffold(
                body: Text('Login'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('renders email field and submit button',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Send Reset Link'), findsOneWidget);
  });

  testWidgets('shows validation error for empty email',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.tap(find.text('Send Reset Link'));
    await tester.pump();

    expect(find.text('Email is required'), findsOneWidget);
  });

  testWidgets('posts the email and shows the check-your-email state',
      (WidgetTester tester) async {
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: '/api/v1/auth/forgot-password'),
        statusCode: 200,
        data: {'message': 'ok'},
      ),
    );

    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), 'user@example.com');
    await tester.tap(find.text('Send Reset Link'));
    await tester.pumpAndSettle();

    verify(() => mockDio.post(
          '/api/v1/auth/forgot-password',
          data: {'email': 'user@example.com'},
        )).called(1);
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.text('Back to Log In'), findsOneWidget);
  });

  testWidgets('shows the mapped failure message from the response',
      (WidgetTester tester) async {
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => throw DioException(
        requestOptions: RequestOptions(path: '/api/v1/auth/forgot-password'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/forgot-password'),
          statusCode: 429,
        ),
        error: RateLimitedException('Too many requests'),
      ),
    );

    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), 'user@example.com');
    await tester.tap(find.text('Send Reset Link'));
    await tester.pumpAndSettle();

    expect(find.text('Too many requests'), findsOneWidget);
    expect(find.text('Check your email'), findsNothing);
  });

  testWidgets('shows a fallback message for a bare failure status',
      (WidgetTester tester) async {
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => throw DioException(
        requestOptions: RequestOptions(path: '/api/v1/auth/forgot-password'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/v1/auth/forgot-password'),
          statusCode: 500,
        ),
      ),
    );

    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), 'user@example.com');
    await tester.tap(find.text('Send Reset Link'));
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong. Try again.'), findsOneWidget);
    expect(find.text('Check your email'), findsNothing);
  });

  testWidgets('shows a loading state while submitting',
      (WidgetTester tester) async {
    final completer = Completer<Response>();
    when(() => mockDio.post(any(), data: any(named: 'data')))
        .thenAnswer((_) => completer.future);

    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), 'user@example.com');
    await tester.tap(find.text('Send Reset Link'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete(Response(
      requestOptions: RequestOptions(path: '/api/v1/auth/forgot-password'),
      statusCode: 200,
      data: {'message': 'ok'},
    ));
    await tester.pumpAndSettle();
    expect(find.text('Check your email'), findsOneWidget);
  });

  testWidgets('navigates to login from back button',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.tap(find.text('Back to Log In'));
    await tester.pumpAndSettle();

    expect(find.text('Login'), findsOneWidget);
  });
}
