import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(AppProfileHeader header) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: header)));

  group('AppProfileHeader initials', () {
    testWidgets('derives the first letters of up to two words', (tester) async {
      // The rider's existing profile suite asserts 'AR' for this exact name.
      await tester.pumpWidget(wrap(const AppProfileHeader(displayName: 'Ana Rojas')));

      expect(find.text('AR'), findsOneWidget);
    });

    testWidgets('takes only two letters from a longer name', (tester) async {
      await tester.pumpWidget(
        wrap(const AppProfileHeader(displayName: 'Ana Maria Rojas Perez')),
      );

      expect(find.text('AM'), findsOneWidget);
    });

    testWidgets('a single-word name yields a single letter', (tester) async {
      // The driver's common case: known bug #3 means a fresh driver has no name,
      // so the app passes the literal 'Driver' and the avatar shows 'D'.
      await tester.pumpWidget(wrap(const AppProfileHeader(displayName: 'Driver')));

      expect(find.text('D'), findsOneWidget);
    });

    testWidgets('supplied initials replace the derived ones', (tester) async {
      // The rider passes 'R' when its *profile* has no name, because its display
      // name falls back to the email and deriving from that would render the
      // email's initial instead.
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(
            displayName: 'ana@example.com',
            initials: 'R',
          ),
        ),
      );

      expect(find.text('R'), findsOneWidget);
      expect(find.text('A'), findsNothing);
    });

    testWidgets('an empty display name renders the avatar alone', (tester) async {
      await tester.pumpWidget(wrap(const AppProfileHeader(displayName: '')));

      expect(find.byType(CircleAvatar), findsOneWidget);
      // No empty Text node, and no invented label: the app owns any fallback.
      expect(find.text(''), findsNothing);
      expect(find.text('Driver'), findsNothing);
    });
  });

  group('AppProfileHeader photo', () {
    testWidgets('a blank photoUrl falls back to initials, never NetworkImage', (tester) async {
      // `DriverProfile.photoUrl` is passed straight through from JSON and is ''
      // for every driver without a photo — the common case. `NetworkImage('')`
      // paints a red error box and throws an unhandled async image error.
      await tester.pumpWidget(
        wrap(const AppProfileHeader(displayName: 'Ava Lopez', photoUrl: '')),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isNull);
      expect(find.text('AL'), findsOneWidget);
    });

    testWidgets('a whitespace-only photoUrl is also absent', (tester) async {
      await tester.pumpWidget(
        wrap(const AppProfileHeader(displayName: 'Ava Lopez', photoUrl: '   ')),
      );

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isNull);
      expect(find.text('AL'), findsOneWidget);
    });

    testWidgets('a real photoUrl is used and suppresses the initials', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(
            displayName: 'Ava Lopez',
            photoUrl: 'https://example.com/ava.png',
          ),
        ),
      );
      // The test binding answers every HTTP request with 400, so the avatar's
      // real image load cannot succeed here. What this case proves is *which
      // provider the widget chose* — that a non-blank url becomes a NetworkImage
      // and the initials are suppressed — so the load failure is drained rather
      // than avoided.
      await tester.pump();
      expect(tester.takeException(), isA<NetworkImageLoadException>());

      final avatar = tester.widget<CircleAvatar>(find.byType(CircleAvatar));
      expect(avatar.backgroundImage, isA<NetworkImage>());
      expect(
        (avatar.backgroundImage! as NetworkImage).url,
        'https://example.com/ava.png',
      );
      expect(find.text('AL'), findsNothing);
    });

    test('normalisePhotoUrl collapses the two models shapes to one', () {
      expect(normalisePhotoUrl(null), isNull);
      expect(normalisePhotoUrl(''), isNull);
      expect(normalisePhotoUrl('   '), isNull);
      expect(normalisePhotoUrl(' https://x/y.png '), 'https://x/y.png');
    });

    test('deriveInitials is the rule both apps hand-rolled', () {
      expect(deriveInitials('Ana Rojas'), 'AR');
      expect(deriveInitials('Ava'), 'A');
      expect(deriveInitials('  Ana   Maria  Rojas '), 'AM');
      expect(deriveInitials(''), '');
      expect(deriveInitials('ana'), 'A');
    });
  });

  group('AppProfileHeader secondary line', () {
    testWidgets('renders the email under the name', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(
            displayName: 'Ana Rojas',
            secondaryLine: 'ana@example.com',
          ),
        ),
      );

      expect(find.text('Ana Rojas'), findsOneWidget);
      expect(find.text('ana@example.com'), findsOneWidget);
    });

    testWidgets('is hidden when it equals the display name', (tester) async {
      // The rider falls back to the email as its display name, so without this
      // rule the address prints twice. Asserted by the rider's profile suite.
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(
            displayName: 'ana@example.com',
            secondaryLine: 'ana@example.com',
          ),
        ),
      );

      expect(find.text('ana@example.com'), findsOneWidget);
    });

    testWidgets('is hidden when it is empty', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(displayName: 'Ana Rojas', secondaryLine: '  '),
        ),
      );

      expect(find.text('Ana Rojas'), findsOneWidget);
      expect(find.text('  '), findsNothing);
    });
  });

  group('AppProfileHeader driver extras', () {
    testWidgets('status dot and rating rows render only when supplied', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(
            displayName: 'Ava Lopez',
            statusLabel: 'online',
            statusColor: Colors.green,
            ratingLabel: '★ 4.8',
          ),
        ),
      );

      expect(find.text('online'), findsOneWidget);
      expect(find.text('★ 4.8'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);

      final dot = tester.widget<Container>(find.byKey(const Key('status-dot')));
      expect((dot.decoration! as BoxDecoration).color, Colors.green);
    });

    testWidgets('a rider header renders no dot, no rating and no chip', (tester) async {
      await tester.pumpWidget(wrap(const AppProfileHeader(displayName: 'Ana Rojas')));

      expect(find.byIcon(Icons.star), findsNothing);
      expect(find.byType(Chip), findsNothing);
      expect(find.byKey(const Key('status-dot')), findsNothing);
      expect(find.text('online'), findsNothing);
    });

    testWidgets('the chip renders whenever statusChipLabel is non-null', (tester) async {
      // The rider asserts `find.text('idle')` and nothing else on its profile
      // screen prints the status, so dropping this chip turns that test red.
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(displayName: 'Ana Rojas', statusChipLabel: 'idle'),
        ),
      );

      expect(find.byType(Chip), findsOneWidget);
      expect(find.text('idle'), findsOneWidget);
    });

    testWidgets('the driver onboarding chip renders its own copy', (tester) async {
      await tester.pumpWidget(
        wrap(
          const AppProfileHeader(
            displayName: 'Driver',
            statusChipLabel: 'Onboarding pending',
          ),
        ),
      );

      expect(find.text('Onboarding pending'), findsOneWidget);
    });

    testWidgets('a blank rating label renders no row', (tester) async {
      await tester.pumpWidget(
        wrap(const AppProfileHeader(displayName: 'Ava Lopez', ratingLabel: '  ')),
      );

      expect(find.byIcon(Icons.star), findsNothing);
    });
  });
}
