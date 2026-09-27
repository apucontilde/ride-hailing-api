import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// The rider's five destinations — the list `buildRiderNavItems()` produces.
List<AppNavItem> fiveItems() => [
      AppNavItem(destination: AppNavDestination.profile, route: '/profile'),
      AppNavItem(
        destination: AppNavDestination.rideHistory,
        label: 'History',
        route: '/history',
      ),
      AppNavItem(destination: AppNavDestination.payment, route: '/payment'),
      AppNavItem(destination: AppNavDestination.security, route: '/security'),
      AppNavItem(destination: AppNavDestination.settings, route: '/settings'),
    ];

void main() {
  /// Pumps [sidebar] as a real drawer and opens it with the shared toggle button.
  ///
  /// Returns the body's context, which is what an app passes to `closeSidebar`:
  /// it sits below the `Scaffold`, so `Navigator.of` resolves to the navigator
  /// the drawer route was pushed onto.
  Future<BuildContext> pumpOpenSidebar(
    WidgetTester tester, {
    required AppSidebar sidebar,
  }) async {
    late BuildContext bodyContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(leading: const AppSidebarToggleButton()),
          drawer: sidebar,
          body: Builder(
            builder: (context) {
              bodyContext = context;
              return const Text('home body');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byType(AppSidebarToggleButton));
    await tester.pumpAndSettle();
    return bodyContext;
  }

  group('AppSidebar sections', () {
    testWidgets('renders the four headings in enum order', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
        ),
      );

      // Read the headings back in paint order rather than asserting four
      // independent `findsOneWidget`s: order is the parity guarantee, and four
      // green finders would not catch SAFETY rendering above ACTIVITY.
      const headings = ['ACCOUNT', 'ACTIVITY', 'SAFETY', 'APP'];
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => headings.contains(d))
          .toList();
      expect(rendered, headings);
    });

    testWidgets('omits a section that has no items', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: [
            AppNavItem(destination: AppNavDestination.profile, route: '/profile'),
            AppNavItem(
              destination: AppNavDestination.settings,
              route: '/settings',
            ),
          ],
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('ACCOUNT'), findsOneWidget);
      expect(find.text('APP'), findsOneWidget);
      expect(find.text('ACTIVITY'), findsNothing);
      expect(find.text('SAFETY'), findsNothing);
    });

    testWidgets('groups items under their own section heading', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
        ),
      );

      final activity = tester.getTopLeft(find.text('ACTIVITY'));
      final history = tester.getTopLeft(find.text('History'));
      final payment = tester.getTopLeft(find.text('Payment'));
      final safety = tester.getTopLeft(find.text('SAFETY'));
      expect(history.dy, greaterThan(activity.dy));
      expect(payment.dy, greaterThan(history.dy));
      expect(safety.dy, greaterThan(payment.dy));
    });
  });

  group('AppSidebar items', () {
    testWidgets('every row is findable by its id key, not its label', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
        ),
      );

      // Labels are overridable per app, so a suite that matched on text would
      // pass in one app and fail in the other.
      for (final id in ['profile', 'ride-history', 'payment', 'security', 'settings']) {
        expect(find.byKey(Key('sidebar-item-$id')), findsOneWidget, reason: id);
      }
    });

    testWidgets('the rider label override renders, the others stay canonical', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('History'), findsOneWidget);
      expect(find.text('Ride history'), findsNothing);
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('tapping a row reports that item and navigates nowhere itself', (tester) async {
      AppNavItem? tapped;
      final bodyContext = await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (item) => tapped = item,
        ),
      );

      await tester.tap(find.byKey(const Key('sidebar-item-payment')));
      await tester.pumpAndSettle();

      expect(tapped, isNotNull);
      expect(tapped!.id, 'payment');
      expect(tapped!.route, '/payment');
      // Navigation is app-owned: nothing here pushed a route, and the drawer is
      // still open because only the app calls closeSidebar.
      expect(find.text('home body'), findsOneWidget);
      expect(find.byKey(const Key('sidebar-item-payment')), findsOneWidget);
      expect(bodyContext.mounted, isTrue);
    });

    testWidgets('selectedRoute highlights exactly one row', (tester) async {
      // Reserved parameter: no app passes it yet (the sidebar only exists on
      // /home today, where nothing is selected), so this is its only coverage.
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
          selectedRoute: '/payment',
        ),
      );

      final rows = tester.widgetList<AppSidebarItem>(find.byType(AppSidebarItem));
      expect(rows.where((r) => r.selected).length, 1);
      expect(rows.firstWhere((r) => r.selected).label, 'Payment');
    });

    testWidgets('no row is highlighted when selectedRoute is omitted', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
        ),
      );

      final rows = tester.widgetList<AppSidebarItem>(find.byType(AppSidebarItem));
      expect(rows.every((r) => !r.selected), isTrue);
    });
  });

  group('AppSidebar header', () {
    testWidgets('shows the name, the secondary line and derived initials', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(
            displayName: 'Ana Rojas',
            secondaryLine: 'ana@example.com',
          ),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('Ana Rojas'), findsOneWidget);
      expect(find.text('ana@example.com'), findsOneWidget);
      expect(find.text('AR'), findsOneWidget);
    });

    testWidgets('hides the secondary line when it equals the display name', (tester) async {
      // The rider falls back to the email as the display name when the profile
      // has no name; printing it twice is the bug this rule prevents.
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(
            displayName: 'ana@example.com',
            secondaryLine: 'ana@example.com',
          ),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('ana@example.com'), findsOneWidget);
    });

    testWidgets('hides an empty secondary line', (tester) async {
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(
            displayName: 'Ana Rojas',
            secondaryLine: '   ',
          ),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('Ana Rojas'), findsOneWidget);
      expect(find.text('   '), findsNothing);
    });

    testWidgets('statusLabel beats secondaryLine', (tester) async {
      // The driver passes a status and no email. Passing both must render one
      // line, not the status twice.
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(
            displayName: 'Ava Lopez',
            secondaryLine: 'ava@example.com',
            statusLabel: 'online',
            statusColor: Colors.green,
          ),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('online'), findsOneWidget);
      expect(find.text('ava@example.com'), findsNothing);
      final dot = tester.widget<Container>(find.byKey(const Key('status-dot')));
      expect((dot.decoration! as BoxDecoration).color, Colors.green);
    });

    testWidgets('supplied initials are used instead of derived ones', (tester) async {
      // Reserved parameter: no app passes it yet, so this is its only coverage.
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(
            displayName: 'Ana Rojas',
            initials: 'R',
          ),
          onItemSelected: (_) {},
        ),
      );

      expect(find.text('R'), findsOneWidget);
      expect(find.text('AR'), findsNothing);
    });

    testWidgets('tapping the header invokes onAccountPressed', (tester) async {
      var pressed = 0;
      await pumpOpenSidebar(
        tester,
        sidebar: AppSidebar(
          items: fiveItems(),
          account: const AppSidebarAccount(displayName: 'Ana Rojas'),
          onItemSelected: (_) {},
          onAccountPressed: () => pressed++,
        ),
      );

      await tester.tap(find.text('Ana Rojas'));
      await tester.pumpAndSettle();
      expect(pressed, 1);
    });
  });

  group('closeSidebar', () {
    testWidgets('pops the enclosing route', (tester) async {
      var selectedRoute = 'none';
      late BuildContext bodyContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(leading: const AppSidebarToggleButton()),
            drawer: AppSidebar(
              items: fiveItems(),
              account: const AppSidebarAccount(displayName: 'Ana Rojas'),
              // Exactly the two lines both apps write at every call site.
              onItemSelected: (item) {
                closeSidebar(bodyContext);
                selectedRoute = item.route;
              },
            ),
            body: Builder(
              builder: (context) {
                bodyContext = context;
                return const Text('home body');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(AppSidebarToggleButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sidebar-item-settings')), findsOneWidget);

      await tester.tap(find.byKey(const Key('sidebar-item-settings')));
      await tester.pumpAndSettle();

      expect(selectedRoute, '/settings');
      // The drawer is gone: popping before pushing is what stops it staying open
      // on top of the destination.
      expect(find.byKey(const Key('sidebar-item-settings')), findsNothing);
      expect(find.text('home body'), findsOneWidget);
    });
  });
}
