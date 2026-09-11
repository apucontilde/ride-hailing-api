import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/app.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';

class _InMemoryAuthStorage extends AuthStorage {
  final _store = <String, String>{};

  _InMemoryAuthStorage() : super(storage: null);

  @override
  Future<void> saveAccessToken(String token) async {
    _store['access_token'] = token;
  }

  @override
  Future<void> saveRefreshToken(String token) async {
    _store['refresh_token'] = token;
  }

  @override
  Future<String?> getAccessToken() async => _store['access_token'];

  @override
  Future<String?> getRefreshToken() async => _store['refresh_token'];

  @override
  Future<void> clearTokens() async {
    _store.remove('access_token');
    _store.remove('refresh_token');
  }

  @override
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    _store['access_token'] = accessToken;
    _store['refresh_token'] = refreshToken;
  }
}

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  testWidgets('Full auth flow: register -> login -> auto-login -> logout',
      (WidgetTester tester) async {
    final inMemoryStorage = _InMemoryAuthStorage();
    final dio = Dio();
    final mockApiClient = MockApiClient();
    when(() => mockApiClient.dio).thenReturn(dio);
    
    final dioAdapter = DioAdapter(dio: dio);

    dioAdapter.onPost(
      '/api/v1/auth/register',
      (server) => server.reply(201, {
        'access_token': 'test-access-token',
        'refresh_token': 'test-refresh-token',
        'user': {
          'id': 'user-1',
          'email': 'newuser@test.com',
          'phone': '+1234567890',
        },
      }),
      data: {
        'email': 'newuser@test.com',
        'phone': '+1234567890',
        'password': 'Password1',
      },
    );

    dioAdapter.onPost(
      '/api/v1/auth/login',
      (server) => server.reply(200, {
        'access_token': 'test-access-token',
        'refresh_token': 'test-refresh-token',
        'user': {
          'id': 'user-1',
          'email': 'newuser@test.com',
        },
      }),
      data: {
        'email': 'newuser@test.com',
        'password': 'Password1',
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          authStorageProvider.overrideWithValue(inMemoryStorage),
        ],
        child: const RiderApp(),
      ),
    );

    // Pump multiple times to process async navigation
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    // App starts at splash screen then redirects to login
    expect(find.text('Log In'), findsWidgets);

    // Navigate to register
    await tester.tap(find.text("Don't have an account? Sign up"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Sign Up'), findsWidgets);

    // Fill registration form
    await tester.enterText(find.byType(TextFormField).at(0), 'newuser@test.com');
    await tester.enterText(find.byType(TextFormField).at(1), '+1234567890');
    await tester.enterText(find.byType(TextFormField).at(2), 'Password1');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // After successful registration, should navigate to home
    await tester.pump(const Duration(seconds: 1));
    expect(find.byIcon(Icons.menu), findsOneWidget);
  });
}
