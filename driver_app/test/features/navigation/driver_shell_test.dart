import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/router/app_router.dart';
import 'package:driver_app/features/driver/model/driver_profile.dart';
import 'package:driver_app/features/navigation/driver_shell.dart';

/// Section stand-ins: enough to prove the shell swaps its body and title, with
/// none of the real screens' providers in the way.
class _Stub extends StatelessWidget {
  const _Stub(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Center(child: Text(label));
}

/// Bug #10 coverage: the drawer belongs to the shell, so it is reachable from
/// every top-level section, and `/trip` (outside the shell) must not grow one.
void main() {
  const profile = DriverProfile(
    userId: 'd1',
    firstName: 'Ada',
    lastName: 'Lovelace',
    status: 'online',
  );

  GoRouter buildRouter({required String initial}) => GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            DriverShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (_, _) => const _Stub('Home Section'),
          ),
          GoRoute(
            path: '/profile',
            builder: (_, _) => const _Stub('Profile Section'),
          ),
          GoRoute(
            path: '/settings',
            builder: (_, _) => const _Stub('Settings Section'),
          ),
          GoRoute(
            path: '/vehicle',
            builder: (_, _) => const _Stub('Vehicle Section'),
          ),
          GoRoute(
            path: '/rides-history',
            builder: (_, _) => const _Stub('History Section'),
          ),
        ],
      ),
      // Outside the shell, exactly like the real router.
      GoRoute(
        path: '/trip',
        builder: (_, _) => const Scaffold(body: Text('Trip Section')),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) => const Scaffold(body: Text('Log In')),
      ),
    ],
  );

  Future<void> pumpShell(
    WidgetTester tester, {
    String initial = '/home',
  }) async {
    final container = ProviderContainer(
      overrides: [driverProfileProvider.overrideWith((ref) => profile)],
    );
    addTearDown(container.dispose);
    final router = buildRouter(initial: initial);
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byType(AppSidebarToggleButton));
    await tester.pumpAndSettle();
  }

  testWidgets('the drawer opens from a non-home section', (tester) async {
    await pumpShell(tester, initial: '/settings');

    expect(find.text('Settings Section'), findsOneWidget);
    expect(find.byType(AppSidebar), findsNothing);

    await openDrawer(tester);

    expect(find.byType(AppSidebar), findsOneWidget);
    // The shell header still carries the driver's identity on any section.
    expect(
      find.descendant(
        of: find.byType(AppSidebarHeader),
        matching: find.text('Ada Lovelace'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the drawer opens from /rides-history too', (tester) async {
    await pumpShell(tester, initial: '/rides-history');

    await openDrawer(tester);

    expect(find.byType(AppSidebar), findsOneWidget);
  });

  testWidgets('/trip has no drawer and no toggle', (tester) async {
    await pumpShell(tester, initial: '/trip');

    expect(find.text('Trip Section'), findsOneWidget);
    expect(find.byType(AppSidebarToggleButton), findsNothing);
    expect(find.byType(AppSidebar), findsNothing);
  });

  testWidgets('a sidebar item routes to its section', (tester) async {
    await pumpShell(tester);

    await openDrawer(tester);
    await tester.tap(find.byKey(const Key('sidebar-item-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Settings Section'), findsOneWidget);
    // Tapping a row closes the drawer before pushing.
    expect(find.byType(AppSidebar), findsNothing);
  });

  testWidgets('the AppBar title follows the section', (tester) async {
    await pumpShell(tester);
    expect(find.widgetWithText(AppBar, 'Home'), findsOneWidget);

    await openDrawer(tester);
    await tester.tap(find.byKey(const Key('sidebar-item-profile')));
    await tester.pumpAndSettle();

    expect(find.text('Profile Section'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Profile'), findsOneWidget);
    expect(find.widgetWithText(AppBar, 'Home'), findsNothing);
  });

  testWidgets('selectedRoute highlights the active section', (tester) async {
    await pumpShell(tester, initial: '/rides-history');
    await openDrawer(tester);

    final active = tester.widget<AppSidebarItem>(
      find.byKey(const Key('sidebar-item-ride-history')),
    );
    expect(active.selected, isTrue);

    final other = tester.widget<AppSidebarItem>(
      find.byKey(const Key('sidebar-item-settings')),
    );
    expect(other.selected, isFalse);
  });

  testWidgets(
    'the real router wraps exactly the five sections and leaves flows outside',
    (tester) async {
      // Reads the PRODUCTION routerProvider, not the bespoke harness above:
      // deleting the ShellRoute from `app_router.dart` must fail this test even
      // though every other case in the file builds its own router.
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
        '/settings',
        '/vehicle',
        '/rides-history',
      });

      // `/trip` and `/safety` are pushed sub-flows: they must stay at the top
      // level so they keep their own back affordance and gain no drawer. The
      // auth and onboarding screens are outside the shell for the same reason.
      final topPaths = topRoutes
          .whereType<GoRoute>()
          .map((r) => r.path)
          .toSet();
      expect(
        topPaths,
        containsAll([
          '/trip',
          '/safety',
          '/login',
          '/register',
          '/forgot-password',
          '/reset-password',
          '/onboarding',
        ]),
      );
    },
  );
}
