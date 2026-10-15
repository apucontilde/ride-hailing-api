import 'dart:async';
import 'package:flutter/foundation.dart';
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
import 'package:rider_app/core/api/endpoints.dart';
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
    when(
      () => mockStorage.saveTokens(
        accessToken: any(named: 'accessToken'),
        refreshToken: any(named: 'refreshToken'),
      ),
    ).thenAnswer((_) async {});
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => null);
    when(
      () => mockStorage.getRefreshToken(),
    ).thenAnswer((_) async => 'refresh');
    when(() => mockStorage.getRememberedEmail()).thenAnswer((_) async => null);
    when(() => mockStorage.saveRememberedEmail(any())).thenAnswer((_) async {});
    when(
      () => mockWebSocketService.connect(token: any(named: 'token')),
    ).thenAnswer((_) async {});
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
              builder: (context, state) => const Scaffold(body: Text('Home')),
            ),
            GoRoute(
              path: '/register',
              builder: (context, state) =>
                  const Scaffold(body: Text('Register')),
            ),
            GoRoute(
              path: '/forgot-password',
              builder: (context, state) =>
                  const Scaffold(body: Text('Forgot Password')),
            ),
            GoRoute(
              path: '/active-ride',
              builder: (context, state) =>
                  const Scaffold(body: Text('Active Ride')),
            ),
            GoRoute(
              path: '/driver-matching',
              builder: (context, state) =>
                  const Scaffold(body: Text('Matching')),
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

  testWidgets('shows validation errors for empty fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pump();

    expect(find.text('Email is required'), findsOneWidget);
    expect(find.text('Password is required'), findsOneWidget);
  });

  testWidgets('shows error on failed login', (WidgetTester tester) async {
    when(
      () => mockDio.post(any(), data: any(named: 'data')),
    ).thenThrow(ApiException('Invalid credentials', statusCode: 401));

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid credentials'), findsOneWidget);
  });

  testWidgets('shows loading state while logging in', (
    WidgetTester tester,
  ) async {
    final completer = Completer<Response>();
    when(
      () => mockDio.post(any(), data: any(named: 'data')),
    ).thenAnswer((_) => completer.future);

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<ElevatedButton>(find.byType(ElevatedButton)).onPressed,
      isNull,
    );

    completer.complete(
      Response(
        requestOptions: RequestOptions(path: '/auth/login'),
        statusCode: 200,
        data: {
          'access_token': 'token',
          'refresh_token': 'refresh',
          'user': {'id': '1', 'email': 'test@test.com'},
        },
      ),
    );
    await tester.pumpAndSettle();

    // A successful login lands on the authenticated home route.
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('navigates to register screen', (WidgetTester tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.text("Don't have an account? Sign up"));
    await tester.pumpAndSettle();

    expect(find.text('Register'), findsOneWidget);
  });

  testWidgets('navigates to forgot password screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(find.text('Forgot Password'), findsOneWidget);
  });

  testWidgets('is a root screen with no back arrow', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('asks to switch when logging in as another account', (
    WidgetTester tester,
  ) async {
    final postPaths = <String>[];
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
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
          'user': {'id': email, 'email': email},
        },
      );
    });

    await tester.pumpWidget(createApp());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
      listen: false,
    );
    await container.read(authProvider.notifier).login('current@test.com', 'pw');
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'other@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
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

  testWidgets('confirming the switch cancels the session then logs in', (
    WidgetTester tester,
  ) async {
    final postPaths = <String>[];
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer((
      invocation,
    ) async {
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
          'user': {'id': email, 'email': email},
        },
      );
    });

    await tester.pumpWidget(createApp());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LoginScreen)),
      listen: false,
    );
    await container.read(authProvider.notifier).login('current@test.com', 'pw');
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'other@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Switch account'));
    await tester.pumpAndSettle();

    final logoutIndex = postPaths.indexWhere((path) => path.contains('logout'));
    final switchLoginIndex = postPaths.lastIndexWhere(
      (path) => path.contains('login'),
    );
    expect(logoutIndex, isNonNegative);
    expect(switchLoginIndex, greaterThan(logoutIndex));
    expect(container.read(authProvider).user?.email, 'other@test.com');
    expect(find.text('Home'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // [trip] post-auth restore — a fresh login lands on the in-progress ride.
  // ---------------------------------------------------------------------------

  testWidgets('a successful login restores an in-progress ride', (
    WidgetTester tester,
  ) async {
    when(
      () => mockDio.post(any(), data: any(named: 'data')),
    ).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 200,
          data: {
            'access_token': 'token',
            'refresh_token': 'refresh',
            'user': {'id': '1', 'email': 'test@test.com'},
          },
        ));
    when(() => mockDio.get(ApiEndpoints.currentRide)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.currentRide),
        statusCode: 200,
        data: {
          'ride': {'id': 'ride-1', 'status': 'accepted'},
          'stops': <dynamic>[],
        },
      ),
    );

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    expect(find.text('Active Ride'), findsOneWidget);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets('a successful login with no active ride lands on home', (
    WidgetTester tester,
  ) async {
    when(
      () => mockDio.post(any(), data: any(named: 'data')),
    ).thenAnswer((_) async => Response(
          requestOptions: RequestOptions(path: '/auth/login'),
          statusCode: 200,
          data: {
            'access_token': 'token',
            'refresh_token': 'refresh',
            'user': {'id': '1', 'email': 'test@test.com'},
          },
        ));
    when(() => mockDio.get(ApiEndpoints.currentRide)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.currentRide),
        statusCode: 200,
        data: {'ride': null, 'stops': <dynamic>[]},
      ),
    );

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // [auth] Enter-to-submit on web/desktop only. The email field is not tested
  // here: it uses `TextInputAction.next`, which only advances focus and never
  // reaches `_submit` (the predicate unit suite covers the web branch, which
  // `kIsWeb` cannot exercise in a widget test).
  // ---------------------------------------------------------------------------

  Response loginResponse() => Response(
    requestOptions: RequestOptions(path: '/auth/login'),
    statusCode: 200,
    data: {
      'access_token': 'token',
      'refresh_token': 'refresh',
      'user': {'id': '1', 'email': 'test@test.com'},
    },
  );

  testWidgets('desktop Enter submits the password field exactly once', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    when(
      () => mockDio.post(any(), data: any(named: 'data')),
    ).thenAnswer((_) async => loginResponse());

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(TextFormField, 'Password'));
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    verify(() => mockDio.post(any(), data: any(named: 'data'))).called(1);
    expect(find.text('Home'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mobile Enter does not submit the password field', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(TextFormField, 'Password'));
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.text('Home'), findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Enter cannot double-submit while a request is in flight', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final completer = Completer<Response>();
    when(
      () => mockDio.post(any(), data: any(named: 'data')),
    ).thenAnswer((_) => completer.future);

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'test@test.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'Password1',
    );
    await tester.tap(find.widgetWithText(TextFormField, 'Password'));
    await tester.pump();

    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    // `done` unfocuses the field, so re-focus before the second press to prove
    // the guard — not a lost input connection — is what blocks the repeat.
    await tester.tap(find.widgetWithText(TextFormField, 'Password'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    verify(() => mockDio.post(any(), data: any(named: 'data'))).called(1);

    completer.complete(loginResponse());
    await tester.pumpAndSettle();

    debugDefaultTargetPlatformOverride = null;
  });
}
