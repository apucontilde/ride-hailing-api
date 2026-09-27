import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/config.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/features/settings/presentation/settings_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockWebSocketService extends Mock implements WebSocketService {}

/// The first coverage `settings_screen.dart` has ever had — driver known bug #4
/// names profile, settings and vehicle as untested, and the rider has had a
/// settings suite all along.
void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockWebSocketService mockWebSocketService;

  setUp(() {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockWebSocketService = MockWebSocketService();
    // No stored refresh token, so logout() skips `POST /auth/logout` and only the
    // local cleanup path runs.
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
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
          initialLocation: '/settings',
          routes: [
            GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
            GoRoute(
              path: '/login',
              builder: (_, _) => const Scaffold(body: Center(child: Text('Log In'))),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('shows app info, server and sign out', (tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    expect(find.text('Driver App'), findsOneWidget);
    expect(
      find.text('v${ApiConfig.appVersion} · companion to rider_app'),
      findsOneWidget,
    );
    expect(find.text('Server'), findsOneWidget);
    expect(find.text(ApiConfig.baseUrl), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsOneWidget);
  });

  testWidgets('tapping sign out asks for confirmation with the driver copy', (tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Sign out?'), findsOneWidget);
    // The one sentence the two apps differ on: the rider's says "to request
    // rides", and the shared dialog takes it as a parameter.
    expect(
      find.text('You will need to log in again to accept ride requests.'),
      findsOneWidget,
    );
    expect(find.text('You will need to log in again to request rides.'), findsNothing);
  });

  testWidgets('cancelling the dialog keeps the session', (tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Sign out?'), findsNothing);
    verifyNever(() => mockWebSocketService.disconnect());
    verifyNever(() => mockStorage.clearTokens());
  });

  testWidgets('confirming clears the session and returns to /login', (tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
    await tester.pumpAndSettle();

    verify(() => mockWebSocketService.disconnect()).called(1);
    verify(() => mockStorage.clearTokens()).called(1);
    expect(find.text('Log In'), findsOneWidget);
  });
}
