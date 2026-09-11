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
import 'package:rider_app/features/auth/presentation/register_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockDio mockDio;

  setUp(() {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockStorage.saveTokens(
      accessToken: any(named: 'accessToken'),
      refreshToken: any(named: 'refreshToken'),
    )).thenAnswer((_) async {});
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => null);
  });

  Widget createApp() {
    return ProviderScope(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/register',
          routes: [
            GoRoute(
              path: '/register',
              builder: (context, state) => const RegisterScreen(),
            ),
            GoRoute(
              path: '/login',
              builder: (context, state) => const Scaffold(
                body: Text('Login'),
              ),
            ),
            GoRoute(
              path: '/home',
              builder: (context, state) => const Scaffold(
                body: Text('Home'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('renders all form fields', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Sign Up'), findsOneWidget);
  });

  testWidgets('shows validation errors for empty fields',
      (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
    await tester.pump();

    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Phone number is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
  });

  testWidgets('shows error on failed registration',
      (WidgetTester tester) async {
    when(() => mockDio.post(
      any(),
      data: any(named: 'data'),
    )).thenThrow(ConflictException('Email already registered'));

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
        find.byType(TextFormField).at(0), 'new@test.com');
    await tester.enterText(
        find.byType(TextFormField).at(1), '+1234567890');
    await tester.enterText(
        find.byType(TextFormField).at(2), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
    await tester.pumpAndSettle();

    expect(find.text('Email already registered'), findsOneWidget);
  });

  testWidgets('shows loading state while registering',
      (WidgetTester tester) async {
    final completer = Completer<Response>();
    when(() => mockDio.post(
      any(),
      data: any(named: 'data'),
    )).thenAnswer((_) => completer.future);

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
        find.byType(TextFormField).at(0), 'new@test.com');
    await tester.enterText(
        find.byType(TextFormField).at(1), '+1234567890');
    await tester.enterText(
        find.byType(TextFormField).at(2), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );

    completer.complete(Response(
      requestOptions: RequestOptions(path: '/auth/register'),
      statusCode: 201,
      data: {
        'access_token': 'token',
        'refresh_token': 'refresh',
        'user': {'id': '1', 'email': 'new@test.com', 'phone': '+1234567890'},
      },
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('navigates to login screen', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.text('Already have an account? Log in'));
    await tester.pumpAndSettle();

    expect(find.text('Login'), findsOneWidget);
  });
}
