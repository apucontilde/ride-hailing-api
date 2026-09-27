import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(AppSettingsScreen screen) =>
      MaterialApp(home: screen);

  AppSettingsScreen riderScreen({
    Future<void> Function()? onSignOut,
    VoidCallback? onSignOutCompleted,
    String? signOutMessage = 'You will need to log in again to request rides.',
    List<AppSettingsSection> extraSections = const [],
    String? serverUrl = 'http://localhost:8080',
    String title = 'Settings',
  }) {
    return AppSettingsScreen(
      appName: 'Rider App',
      appVersion: '1.0.0',
      serverUrl: serverUrl,
      companionAppName: 'driver_app',
      signOutMessage: signOutMessage,
      onSignOut: onSignOut ?? () async {},
      onSignOutCompleted: onSignOutCompleted,
      extraSections: extraSections,
      title: title,
    );
  }

  group('AppSettingsScreen default rows', () {
    testWidgets('renders the three rows both apps ship today', (tester) async {
      await tester.pumpWidget(wrap(riderScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Rider App'), findsOneWidget);
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('http://localhost:8080'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
      expect(find.byIcon(Icons.dns_outlined), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(3));
    });

    testWidgets('the app-info subtitle is the exact asserted literal', (tester) async {
      await tester.pumpWidget(wrap(riderScreen()));
      await tester.pumpAndSettle();

      // The rider's existing settings suite asserts this string verbatim, so the
      // middle dot, the spacing and the ordering are contract, not cosmetics.
      expect(
        find.text('v1.0.0 · companion to driver_app'),
        findsOneWidget,
      );
    });

    testWidgets('the driver copy renders from the same widget', (tester) async {
      await tester.pumpWidget(
        wrap(
          AppSettingsScreen(
            appName: 'Driver App',
            appVersion: '1.0.0',
            serverUrl: 'http://localhost:8080',
            companionAppName: 'rider_app',
            signOutMessage: 'You will need to log in again to accept ride requests.',
            onSignOut: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Driver App'), findsOneWidget);
      expect(find.text('v1.0.0 · companion to rider_app'), findsOneWidget);
    });

    testWidgets('a null serverUrl omits the server row', (tester) async {
      await tester.pumpWidget(wrap(riderScreen(serverUrl: null)));
      await tester.pumpAndSettle();

      expect(find.text('Server'), findsNothing);
      expect(find.byIcon(Icons.dns_outlined), findsNothing);
      expect(find.byType(Card), findsNWidgets(2));
    });

    testWidgets('an app with neither version nor companion gets no subtitle', (tester) async {
      await tester.pumpWidget(
        wrap(
          AppSettingsScreen(appName: 'Bare App', onSignOut: () async {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bare App'), findsOneWidget);
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('Bare App'), matching: find.byType(ListTile)),
      );
      expect(tile.subtitle, isNull);
    });

    testWidgets('the title parameter overrides the app bar', (tester) async {
      // Reserved parameter: both apps take the 'Settings' default, so this is its
      // only coverage.
      await tester.pumpWidget(wrap(riderScreen(title: 'Preferences')));
      await tester.pumpAndSettle();

      expect(find.text('Preferences'), findsOneWidget);
      expect(find.text('Settings'), findsNothing);
    });
  });

  group('AppSettingsScreen extraSections', () {
    testWidgets('append below the defaults, with heading and reserved slots', (tester) async {
      await tester.pumpWidget(
        wrap(
          riderScreen(
            extraSections: [
              AppSettingsSection(
                title: 'Safety',
                icon: Icons.shield_outlined,
                rows: [
                  AppSettingsRow(
                    leading: Icons.sos_outlined,
                    title: 'SOS contacts',
                    subtitle: 'Who we notify',
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {},
                  ),
                  const AppSettingsRow(
                    leading: Icons.logout,
                    title: 'Erase data',
                    isDestructive: true,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Safety'), findsOneWidget);
      expect(find.byIcon(Icons.shield_outlined), findsOneWidget);
      expect(find.text('SOS contacts'), findsOneWidget);
      expect(find.text('Who we notify'), findsOneWidget);
      expect(find.text('Erase data'), findsOneWidget);
      // The extra group is one card holding both rows, below the three defaults.
      expect(find.byType(Card), findsNWidgets(4));
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      final erase = tester.widget<Text>(find.text('Erase data'));
      expect(erase.style?.color, isNotNull);

      final extraTop = tester.getTopLeft(find.text('Safety'));
      final signOutTop = tester.getTopLeft(find.text('Sign out'));
      expect(extraTop.dy, greaterThan(signOutTop.dy));
    });

    testWidgets('an untitled section renders a bare card', (tester) async {
      await tester.pumpWidget(
        wrap(
          riderScreen(
            extraSections: const [
              AppSettingsSection(
                rows: [AppSettingsRow(title: 'About')],
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('About'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(4));
    });
  });

  group('sign-out flow', () {
    testWidgets('tapping the row asks for confirmation with the app copy', (tester) async {
      await tester.pumpWidget(wrap(riderScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Sign out?'), findsOneWidget);
      expect(
        find.text('You will need to log in again to request rides.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign out'), findsOneWidget);
    });

    testWidgets('cancelling never calls onSignOut', (tester) async {
      var signedOut = false;
      var completed = false;
      await tester.pumpWidget(
        wrap(
          riderScreen(
            onSignOut: () async => signedOut = true,
            onSignOutCompleted: () => completed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(signedOut, isFalse);
      expect(completed, isFalse);
      expect(find.text('Sign out?'), findsNothing);
    });

    testWidgets('confirming calls onSignOut then onSignOutCompleted', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        wrap(
          riderScreen(
            onSignOut: () async => calls.add('signOut'),
            onSignOutCompleted: () => calls.add('completed'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(calls, ['signOut', 'completed']);
    });

    testWidgets('a null signOutMessage renders no dialog body', (tester) async {
      await tester.pumpWidget(wrap(riderScreen(signOutMessage: null)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Sign out?'), findsOneWidget);
      expect(
        find.text('You will need to log in again to request rides.'),
        findsNothing,
      );
    });
  });

  group('performAppSignOut', () {
    testWidgets('does not complete when onSignOut throws', (tester) async {
      // Asserted on the function rather than through a tap: an error escaping a
      // tap callback is an unhandled async error, which would fail the test for
      // the wrong reason.
      late BuildContext context;
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              context = c;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final pending = performAppSignOut(
        context,
        message: 'Are you sure?',
        onSignOut: () async => throw StateError('logout failed'),
        onSignOutCompleted: () => completed = true,
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign out?'), findsOneWidget);
      // Subscribed before the tap: an error that lands on a Future nobody is
      // listening to yet is reported as an unhandled zone error and fails the
      // test for the wrong reason.
      final expectation = expectLater(pending, throwsA(isA<StateError>()));
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();
      await expectation;

      // Navigating to /login after a failed logout is how a half-cleared session
      // survives into the next sign-in.
      expect(completed, isFalse);
    });

    test('showAppSignOutDialog is reachable through the barrel', () {
      // The barrel is unfiltered, so every new symbol is public by construction;
      // this keeps a rename from silently breaking an app that imports it.
      expect(showAppSignOutDialog, isA<Function>());
      expect(performAppSignOut, isA<Function>());
      expect(closeSidebar, isA<Function>());
      expect(normalisePhotoUrl(''), isNull);
      expect(deriveInitials('Ana Rojas'), 'AR');
    });
  });
}
