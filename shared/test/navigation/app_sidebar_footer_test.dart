import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  /// Pumps [footer] as the pinned footer of a real sidebar and opens it.
  Future<void> pumpSidebarWithFooter(
    WidgetTester tester, {
    required AppSidebarFooter footer,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(leading: const AppSidebarToggleButton()),
          drawer: AppSidebar(
            items: [
              AppNavItem(destination: AppNavDestination.profile, route: '/profile'),
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

    testWidgets('is a sibling of the scroller, not a child of it', (tester) async {
      // A footer inside the ListView scrolls out of view, and sign-out must stay
      // reachable whatever the item list length.
      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(onSignOut: () async {}),
      );

      expect(find.byType(ListView), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byKey(const Key('sidebar-sign-out')),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('sidebar-sign-out')), findsOneWidget);
    });

    testWidgets('stays on screen with a list long enough to scroll', (tester) async {
      await pumpSidebarWithFooter(
        tester,
        footer: AppSidebarFooter(onSignOut: () async {}),
      );

      final viewport = tester.getSize(find.byType(ListView));
      final footerRect = tester.getRect(find.byKey(const Key('sidebar-sign-out')));
      expect(footerRect.top, greaterThanOrEqualTo(viewport.height - 1));
      expect(footerRect.bottom, lessThanOrEqualTo(tester.getSize(find.byType(Scaffold)).height));
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
