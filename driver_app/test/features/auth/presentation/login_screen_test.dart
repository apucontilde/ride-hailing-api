import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:go_router/go_router.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/auth/auth_storage.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/api_exceptions.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/features/auth/presentation/login_screen.dart';

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
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => 'refresh');
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
              path: '/onboarding',
              builder: (context, state) => const Scaffold(
                body: Text('Onboarding'),
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

  // Stubs `/auth/login` (echoing credentials) and `/auth/logout`, recording
  // every posted path so the tests can assert ordering.
  List<String> stubAuthPosts() {
    final postPaths = <String>[];
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        postPaths.add(path);
        if (path.contains('logout')) {
          return Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
          );
        }
        final data = invocation.namedArguments[#data] as Map<String, dynamic>;
        final email = data['email'] as String;
        return Response(
          requestOptions: RequestOptions(path: path),
          statusCode: 200,
          data: {
            'access_token': 'access-$email',
            'refresh_token': 'refresh-$email',
            'user': {'id': email, 'email': email, 'role': 'rider'},
          },
        );
      },
    );
    return postPaths;
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
        'user': {'id': '1', 'email': 'test@test.com', 'role': 'rider'},
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

  testWidgets('asks to switch when logging in as another account',
      (WidgetTester tester) async {
    final postPaths = stubAuthPosts();

    await tester.pumpWidget(createApp());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
      listen: false,
    );
    await container.read(authProvider.notifier).login('current@test.com', 'pw');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'other@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    expect(
      find.text('Sign out of current@test.com and sign in as other@test.com?'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(container.read(authProvider).user?.email, 'current@test.com');
    expect(postPaths.where((path) => path.contains('logout')), isEmpty);
  });

  testWidgets('confirming the switch cancels the session then logs in as new',
      (WidgetTester tester) async {
    final postPaths = stubAuthPosts();

    await tester.pumpWidget(createApp());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
      listen: false,
    );
    await container.read(authProvider.notifier).login('current@test.com', 'pw');
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'other@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Switch account'));
    await tester.pumpAndSettle();

    final logoutIndex = postPaths.indexWhere((path) => path.contains('logout'));
    final switchLoginIndex =
        postPaths.lastIndexWhere((path) => path.contains('login'));
    expect(logoutIndex, isNonNegative);
    expect(switchLoginIndex, greaterThan(logoutIndex));
    expect(container.read(authProvider).status, AuthStatus.authenticated);
    expect(container.read(authProvider).user?.email, 'other@test.com');
  });
}
