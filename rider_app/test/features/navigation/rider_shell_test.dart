import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/router/app_router.dart';
import 'package:rider_app/features/navigation/rider_shell.dart';

/// A stand-in body so these tests exercise the shell chrome, not the screens.
class _Body extends StatelessWidget {
  const _Body(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Center(child: Text(label));
}

void main() {
  /// Mirrors the real tree: the six sections share one `ShellRoute` rendered by
  /// [RiderShell]; `/active-ride` stays outside it.
  Future<void> pumpShell(WidgetTester tester, String location) async {
    final router = GoRouter(
      initialLocation: location,
      routes: [
        ShellRoute(
          builder: (context, state, child) =>
              RiderShell(state: state, child: child),
          routes: [
            GoRoute(path: '/home', builder: (_, _) => const _Body('home-body')),
            GoRoute(
              path: '/profile',
              builder: (_, _) => const _Body('profile-body'),
            ),
            GoRoute(
              path: '/history',
              builder: (_, _) => const _Body('history-body'),
            ),
            GoRoute(
              path: '/payment',
              builder: (_, _) => const _Body('payment-body'),
            ),
            GoRoute(
              path: '/security',
              builder: (_, _) => const _Body('security-body'),
            ),
            GoRoute(
              path: '/settings',
              builder: (_, _) => const _Body('settings-body'),
            ),
          ],
        ),
        GoRoute(
          path: '/active-ride',
          builder: (_, _) => const _Body('active-ride-body'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byType(AppSidebarToggleButton));
    await tester.pumpAndSettle();
  }

  testWidgets('the drawer opens from a non-home section via the shell AppBar', (
    tester,
  ) async {
    await pumpShell(tester, '/profile');

    expect(find.byType(AppSidebar), findsNothing);
    expect(find.byType(AppSidebarToggleButton), findsOneWidget);

    await openDrawer(tester);
    expect(find.byType(AppSidebar), findsOneWidget);
  });

  testWidgets('flow routes stay outside the shell and have no drawer', (
    tester,
  ) async {
    await pumpShell(tester, '/active-ride');

    expect(find.text('active-ride-body'), findsOneWidget);
    expect(find.byType(AppSidebarToggleButton), findsNothing);
    expect(find.byType(AppSidebar), findsNothing);
  });

  testWidgets('selectedRoute highlights the active section', (tester) async {
    await pumpShell(tester, '/history');
    await openDrawer(tester);

    final active = tester.widget<AppSidebarItem>(
      find.byKey(const Key('sidebar-item-ride-history')),
    );
    expect(active.selected, isTrue);

    final other = tester.widget<AppSidebarItem>(
      find.byKey(const Key('sidebar-item-payment')),
    );
    expect(other.selected, isFalse);
  });

  testWidgets('a nav tap switches section and the highlight follows', (
    tester,
  ) async {
    await pumpShell(tester, '/profile');
    await openDrawer(tester);

    await tester.tap(find.byKey(const Key('sidebar-item-payment')));
    await tester.pumpAndSettle();

    expect(find.text('payment-body'), findsOneWidget);

    await openDrawer(tester);
    final payment = tester.widget<AppSidebarItem>(
      find.byKey(const Key('sidebar-item-payment')),
    );
    expect(payment.selected, isTrue);
  });

  testWidgets('the shell AppBar title follows the section', (tester) async {
    await pumpShell(tester, '/profile');
    expect(find.text('Profile'), findsOneWidget);

    await openDrawer(tester);
    await tester.tap(find.byKey(const Key('sidebar-item-ride-history')));
    await tester.pumpAndSettle();

    expect(find.text('Ride History'), findsOneWidget);
    expect(find.text('Profile'), findsNothing);
  });

  testWidgets(
    'the real router wraps exactly the six sections and leaves flows outside',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final router = container.read(routerProvider);
      addTearDown(router.dispose);

      final topRoutes = router.configuration.routes;
      final shells = topRoutes.whereType<ShellRoute>().toList();
      expect(shells, hasLength(1));

      final shellPaths = shells.single.routes
          .whereType<GoRoute>()
          .map((r) => r.path)
          .toSet();
      expect(shellPaths, {
        '/home',
        '/profile',
        '/history',
        '/payment',
        '/security',
        '/settings',
      });

      final topPaths = topRoutes
          .whereType<GoRoute>()
          .map((r) => r.path)
          .toSet();
      expect(
        topPaths,
        containsAll(['/location-search', '/driver-matching', '/active-ride']),
      );
    },
  );
}
