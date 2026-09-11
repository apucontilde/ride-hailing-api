import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:rider_app/features/auth/presentation/forgot_password_screen.dart';

void main() {
  Widget createTestWidget() {
    return ProviderScope(
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

  testWidgets('shows success message after submitting valid email',
      (WidgetTester tester) async {
    await tester.pumpWidget(createTestWidget());
    await tester.pump();

    await tester.enterText(find.byType(TextFormField), 'user@example.com');
    await tester.tap(find.text('Send Reset Link'));
    await tester.pump();

    expect(find.text('Check your email'), findsOneWidget);
    expect(find.text('Back to Log In'), findsOneWidget);
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
