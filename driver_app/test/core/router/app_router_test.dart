import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/core/router/app_router.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/auth/auth_storage.dart';
import 'package:driver_app/features/auth/presentation/login_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

/// The router's splash gate and the `unauthenticated → /login` redirect, driven
/// through the real `routerProvider` with an empty session. No network: a null
/// access token makes `checkAuth()` settle unauthenticated locally.
void main() {
  ProviderContainer buildContainer() {
    final storage = MockAuthStorage();
    when(() => storage.getAccessToken()).thenAnswer((_) async => null);
    // LoginScreen reads the remembered email on mount.
    when(() => storage.getRememberedEmail()).thenAnswer((_) async => null);
    final container = ProviderContainer(
      overrides: [authStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the splash gate lands an empty session on /login', (tester) async {
    await pumpApp(tester, buildContainer());

    // SplashScreen.checkAuth() runs, sees no token, and redirects.
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('an unauthenticated request for a protected route redirects to /login',
      (tester) async {
    final container = buildContainer();
    await pumpApp(tester, container);

    container.read(routerProvider).go('/home');
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
  });
}