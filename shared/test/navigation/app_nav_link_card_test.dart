import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(AppNavLinkCard card) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: card)));

  /// The rider's profile-screen card: its own destination list minus `profile`,
  /// which is the page the card sits on.
  List<AppNavItem> cardItems() => [
        AppNavItem(
          destination: AppNavDestination.rideHistory,
          label: 'History',
          route: '/history',
        ),
        AppNavItem(destination: AppNavDestination.payment, route: '/payment'),
        AppNavItem(destination: AppNavDestination.settings, route: '/settings'),
      ];

  group('AppNavLinkCard', () {
    testWidgets('renders one row per item, in order', (tester) async {
      await tester.pumpWidget(
        wrap(AppNavLinkCard(items: cardItems(), onItemSelected: (_) {})),
      );

      expect(find.text('History'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(3));

      final labels = tester
          .widgetList<ListTile>(find.byType(ListTile))
          .map((tile) => (tile.title! as Text).data)
          .toList();
      expect(labels, ['History', 'Payment', 'Settings']);
    });

    testWidgets('rows are separated by a hairline divider', (tester) async {
      await tester.pumpWidget(
        wrap(AppNavLinkCard(items: cardItems(), onItemSelected: (_) {})),
      );

      // n rows, n-1 dividers, each the 1 px hairline the two apps used.
      final dividers = tester.widgetList<Divider>(find.byType(Divider));
      expect(dividers.length, 2);
      expect(dividers.every((d) => d.height == 1), isTrue);
    });

    testWidgets('a single item renders no divider', (tester) async {
      await tester.pumpWidget(
        wrap(
          AppNavLinkCard(
            items: [
              AppNavItem(
                destination: AppNavDestination.settings,
                route: '/settings',
              ),
            ],
            onItemSelected: (_) {},
          ),
        ),
      );

      expect(find.byType(ListTile), findsOneWidget);
      expect(find.byType(Divider), findsNothing);
    });

    testWidgets("each row's tap reports its own item", (tester) async {
      final tapped = <AppNavItem>[];
      await tester.pumpWidget(
        wrap(AppNavLinkCard(items: cardItems(), onItemSelected: tapped.add)),
      );

      await tester.tap(find.text('Payment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(tapped.map((i) => i.id), ['payment', 'settings']);
      expect(tapped.map((i) => i.route), ['/payment', '/settings']);
    });

    testWidgets('reads icon and label from the same item the sidebar reads', (tester) async {
      // The point of sharing the type: the rider's card used Icons.credit_card
      // for /payment while its own sidebar used Icons.payment for the same
      // destination. Both now resolve from AppNavDestination.
      await tester.pumpWidget(
        wrap(AppNavLinkCard(items: cardItems(), onItemSelected: (_) {})),
      );

      expect(find.byIcon(AppNavDestination.payment.icon), findsOneWidget);
      expect(find.byIcon(Icons.credit_card), findsNothing);
      expect(find.byIcon(AppNavDestination.rideHistory.icon), findsOneWidget);
      // The card carries no subtitle slot: AppNavItem has label, icon and route
      // only, and the apps' seven subtitles are a recorded content loss.
      expect(find.text('Past trips'), findsNothing);
      expect(find.text('Cards & receipts'), findsNothing);
    });

    testWidgets('rows carry an id key so an app can assert absence', (tester) async {
      // The driver's stage asserts /vehicle is absent from BOTH the sidebar and
      // this card; that needs a finder that does not depend on the label.
      await tester.pumpWidget(
        wrap(AppNavLinkCard(items: cardItems(), onItemSelected: (_) {})),
      );

      expect(find.byKey(const Key('nav-link-payment')), findsOneWidget);
      expect(find.byKey(const Key('nav-link-vehicle')), findsNothing);
    });
  });
}
