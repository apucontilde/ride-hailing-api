import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/features/auth/presentation/register_screen.dart';

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
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
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
          initialLocation: '/register',
          routes: [
            GoRoute(
              path: '/register',
              builder: (context, state) => const RegisterScreen(),
            ),
            // A brand-new account is role `rider`; `RegisterScreen` routes it
            // to onboarding (US-D1).
            GoRoute(
              path: '/onboarding',
              builder: (context, state) =>
                  const Scaffold(body: Text('Onboarding')),
            ),
            GoRoute(
              path: '/login',
              builder: (context, state) => const Scaffold(body: Text('Login')),
            ),
          ],
        ),
      ),
    );
  }

  /// Stubs `/auth/register` then the `login()` it chains into, recording every
  /// posted path so the tests can count the register calls.
  List<String> stubAuthPosts() {
    final postPaths = <String>[];
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) async {
        final path = invocation.positionalArguments.first as String;
        postPaths.add(path);
        if (path.contains('register')) {
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
            'access_token': 'access',
            'refresh_token': 'refresh',
            'user': {'id': email, 'email': email, 'role': 'rider'},
          },
        );
      },
    );
    return postPaths;
  }

  testWidgets('renders email, phone and password fields', (tester) async {
    await tester.pumpWidget(createApp());
    await tester.pump();

    expect(find.byType(AppTextField), findsNWidgets(3));
    expect(find.widgetWithText(ElevatedButton, 'Sign Up'), findsOneWidget);
    // Email/phone advance, password submits.
    expect(
      tester.widget<TextField>(find.byType(TextField).at(0)).textInputAction,
      TextInputAction.next,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).textInputAction,
      TextInputAction.next,
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).textInputAction,
      TextInputAction.done,
    );
  });

  testWidgets('the password field submits the registration on Enter',
      (tester) async {
    final postPaths = stubAuthPosts();

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), 'new@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), '12345678');
    await tester.enterText(find.byType(TextFormField).at(2), 'Password1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(postPaths.where((path) => path.contains('register')), hasLength(1));
    expect(find.text('Onboarding'), findsOneWidget);
  });

  testWidgets('a second Enter while registering sends no second POST',
      (tester) async {
    final registerCompleter = Completer<Response>();
    final postPaths = <String>[];
    when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
      (invocation) {
        final path = invocation.positionalArguments.first as String;
        postPaths.add(path);
        if (path.contains('register')) {
          return registerCompleter.future;
        }
        return Future.value(
          Response(
            requestOptions: RequestOptions(path: path),
            statusCode: 200,
            data: {
              'access_token': 'access',
              'refresh_token': 'refresh',
              'user': {
                'id': 'new@test.com',
                'email': 'new@test.com',
                'role': 'rider',
              },
            },
          ),
        );
      },
    );

    await tester.pumpWidget(createApp());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField).at(0), 'new@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), '12345678');
    await tester.enterText(find.byType(TextFormField).at(2), 'Password1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(postPaths.where((path) => path.contains('register')), hasLength(1));

    registerCompleter.complete(
      Response(
        requestOptions: RequestOptions(path: '/auth/register'),
        statusCode: 200,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Onboarding'), findsOneWidget);
  });
}
