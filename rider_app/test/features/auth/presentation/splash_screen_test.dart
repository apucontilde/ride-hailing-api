import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/app.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/auth/presentation/login_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

class MockWebSocketService extends Mock implements WebSocketService {}

void main() {
  testWidgets(
      'cold start with no token shows the spinner then redirects to /login',
      (WidgetTester tester) async {
    final storage = MockAuthStorage();
    final webSocketService = MockWebSocketService();
    when(() => storage.getAccessToken()).thenAnswer((_) async => null);
    when(() => storage.getRememberedEmail()).thenAnswer((_) async => null);
    when(() => webSocketService.disconnect()).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStorageProvider.overrideWithValue(storage),
          webSocketServiceProvider.overrideWithValue(webSocketService),
        ],
        child: const RiderApp(),
      ),
    );

    // First frame is the splash spinner while `checkAuth()` is in flight.
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // `checkAuth()` finds no session, so the splash drives the startup redirect
    // to the login route rather than sitting on the spinner.
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
