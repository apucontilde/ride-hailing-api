import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('AppSidebarToggleButton', () {
    testWidgets('opens the drawer from an AppBar leading slot', (tester) async {
      // The driver's placement: today Flutter supplies its own implicit
      // hamburger here, so this is the widget that replaces it.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(leading: const AppSidebarToggleButton()),
            drawer: AppSidebar(
              items: [
                AppNavItem(
                  destination: AppNavDestination.settings,
                  route: '/settings',
                ),
              ],
              account: const AppSidebarAccount(displayName: 'Ava Lopez'),
              onItemSelected: (_) {},
            ),
            body: const Text('home body'),
          ),
        ),
      );

      expect(find.byKey(const Key('sidebar-item-settings')), findsNothing);
      await tester.tap(find.byType(AppSidebarToggleButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sidebar-item-settings')), findsOneWidget);
    });

    testWidgets('opens the drawer from a Positioned overlay in the body', (tester) async {
      // The rider's placement: no AppBar at all, the button floats over an
      // edge-to-edge map inside a Stack.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            drawer: AppSidebar(
              items: [
                AppNavItem(
                  destination: AppNavDestination.settings,
                  route: '/settings',
                ),
              ],
              account: const AppSidebarAccount(displayName: 'Ana Rojas'),
              onItemSelected: (_) {},
            ),
            body: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.green)),
                Positioned(
                  top: 8,
                  left: 16,
                  child: SafeArea(
                    child: AppSidebarToggleButton(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white,
                        elevation: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.byType(AppSidebarToggleButton));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sidebar-item-settings')), findsOneWidget);
    });

    testWidgets('the default icon is Icons.menu', (tester) async {
      // Regression guard: the rider's `auth_flow_test.dart` and
      // `home_screen_test.dart` both locate this button with
      // `find.byIcon(Icons.menu)`, so the default may not change.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppSidebarToggleButton())),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
    });

    testWidgets('an explicit icon overrides the default', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppSidebarToggleButton(icon: Icons.menu_open),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.menu_open), findsOneWidget);
      expect(find.byIcon(Icons.menu), findsNothing);
    });

    testWidgets('style overrides the button chrome', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppSidebarToggleButton(
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white,
                  elevation: 2,
                ),
              ),
            ),
          ),
        ),
      );

      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.style, isNotNull);
      final background = button.style?.backgroundColor?.resolve(<WidgetState>{});
      expect(background, Colors.white);
    });

    testWidgets('a null icon falls back to Icons.menu', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: AppSidebarToggleButton(icon: null))),
        ),
      );

      expect(find.byIcon(Icons.menu), findsOneWidget);
    });

    testWidgets('tooltip is passed through', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: AppSidebarToggleButton(tooltip: 'Open menu')),
          ),
        ),
      );

      expect(tester.widget<IconButton>(find.byType(IconButton)).tooltip, 'Open menu');
    });
  });
}
