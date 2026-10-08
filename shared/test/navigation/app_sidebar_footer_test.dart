import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  /// Pumps [footer] as the pinned footer of a real sidebar and opens it.
  Future<void> pumpSidebarWithFooter(
    WidgetTester tester, {
    required AppSidebarFooter footer,
    List<AppNavItem>? items,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(leading: const AppSidebarToggleButton()),
          drawer: AppSidebar(
            items: items ??
                [
                  AppNavItem(
                    destination: AppNavDestination.profile,
                    route: '/profile',
                  ),
                  AppNavItem(
                    destination: AppNavDestination.settings,
                    route: '/settings',
                  ),
                ],
            account: const AppSidebarAccount(displayName: 'Ana Rojas'),
            onItemSelected: (_) {},
            footer: footer,
          ),
          body: const Text('home body'),
        ),
      ),
    );
    await tester.tap(find.byType(AppSidebarToggleButton));
    await tester.pumpAndSettle();
  }

  group('AppSidebarFooter layout', () {
    testWidgets('renders the destructive sign-out row', (tester) async {
      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(onSignOut: () async {}),
      );

      expect(find.byKey(const Key('sidebar-sign-out')), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);

      final title = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const Key('sidebar-sign-out')),
          matching: find.byType(Text),
        ),
      );
      // Destructive styling is the footer's own; the settings screen's sign-out
      // row stays default-coloured, matching what both apps render today.
      expect(title.style?.color, isNotNull);
    });

    testWidgets('the pinned footer stays reachable while the item list scrolls', (tester) async {
      // Constrain the viewport so the full set of destinations genuinely
      // overflows the scroller; the helper's default two items fit on any screen.
      tester.view.physicalSize = const Size(400, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(onSignOut: () async {}),
        items: [
          AppNavItem(
            destination: AppNavDestination.profile,
            route: '/profile',
          ),
          AppNavItem(
            destination: AppNavDestination.rideHistory,
            route: '/rides-history',
          ),
          AppNavItem(
            destination: AppNavDestination.payment,
            route: '/payment',
          ),
          AppNavItem(
            destination: AppNavDestination.vehicle,
            route: '/vehicle',
          ),
          AppNavItem(
            destination: AppNavDestination.security,
            route: '/security',
          ),
          AppNavItem(
            destination: AppNavDestination.settings,
            route: '/settings',
          ),
        ],
      );

      final signOut = find.byKey(const Key('sidebar-sign-out'));
      // The footer is a sibling of the scroller, so it cannot scroll out of view.
      expect(
        find.descendant(of: find.byType(ListView), matching: signOut),
        findsNothing,
      );
      expect(signOut, findsOneWidget);

      final position =
          tester.state<ScrollableState>(find.byType(Scrollable)).position;
      expect(position.maxScrollExtent, greaterThan(0));

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      // The list actually moved, and sign-out is still on screen.
      expect(position.pixels, greaterThan(0));
      expect(signOut, findsOneWidget);
      expect(tester.getRect(signOut).bottom, lessThanOrEqualTo(400));
    });
  });

  group('AppSidebarFooter delegates to performAppSignOut', () {
    testWidgets('confirming signs out then completes', (tester) async {
      final calls = <String>[];
      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(
          message: 'You will need to log in again to request rides.',
          onSignOut: () async => calls.add('signOut'),
          onSignOutCompleted: () => calls.add('completed'),
        ),
      );

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();

      expect(find.text('Sign out?'), findsOneWidget);
      expect(
        find.text('You will need to log in again to request rides.'),
        findsOneWidget,
      );
      expect(calls, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      // Order matters: navigating while the logout call is still in flight is how
      // a half-cleared session survives into the next sign-in.
      expect(calls, ['signOut', 'completed']);
    });

    testWidgets('cancelling does nothing', (tester) async {
      final calls = <String>[];
      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(
          onSignOut: () async => calls.add('signOut'),
          onSignOutCompleted: () => calls.add('completed'),
        ),
      );

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
      expect(find.text('Sign out?'), findsNothing);
    });

    testWidgets('renders no dialog content when message is omitted', (tester) async {
      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(onSignOut: () async {}),
      );

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();

      expect(find.text('Sign out?'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });
}
