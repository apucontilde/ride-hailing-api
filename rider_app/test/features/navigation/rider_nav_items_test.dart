import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/features/navigation/rider_nav_items.dart';

void main() {
  group('buildRiderNavItems identity', () {
    test('lists exactly the five rider destinations', () {
      expect(buildRiderNavItems(), hasLength(5));
    });

    test('ids are the kebab-case strings the sidebar keys are built from', () {
      // `Key('sidebar-item-<id>')` is how every sidebar suite finds a row, so
      // these strings are a test contract rather than an implementation detail.
      expect(
        buildRiderNavItems().map((i) => i.id),
        ['profile', 'ride-history', 'payment', 'security', 'settings'],
      );
    });

    test('has no duplicate ids', () {
      final ids = buildRiderNavItems().map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('routes are the rider router paths', () {
      // The driver's history lives at /rides-history; the rider's at /history.
      // Routes are the app-owned half of the seam, so they are asserted here and
      // nowhere in shared/.
      expect(
        buildRiderNavItems().map((i) => i.route),
        ['/profile', '/history', '/payment', '/security', '/settings'],
      );
    });

    test('carries no vehicle destination', () {
      expect(
        buildRiderNavItems().where((i) => i.destination == AppNavDestination.vehicle),
        isEmpty,
      );
    });
  });

  group('buildRiderNavItems parity guarantees', () {
    test('every icon is the canonical one', () {
      // Icons are one of the two things the rider may not diverge on: the drawer
      // used to call /payment Icons.payment while the profile card called the
      // same destination Icons.credit_card.
      expect(
        buildRiderNavItems().map((i) => i.icon),
        [
          Icons.person_outline,
          Icons.history,
          Icons.payment,
          Icons.shield_outlined,
          Icons.settings_outlined,
        ],
      );
      for (final item in buildRiderNavItems()) {
        expect(item.icon, item.destination.icon, reason: item.id);
      }
    });

    test('every section is the canonical one, in group order', () {
      expect(
        buildRiderNavItems().map((i) => i.section),
        [
          AppNavSection.account,
          AppNavSection.activity,
          AppNavSection.activity,
          AppNavSection.safety,
          AppNavSection.app,
        ],
      );
      for (final item in buildRiderNavItems()) {
        expect(item.section, item.destination.section, reason: item.id);
      }
    });

    test("the only label override is 'History' on ride-history", () {
      for (final item in buildRiderNavItems()) {
        if (item.destination == AppNavDestination.rideHistory) {
          // Deliberate divergence from the driver's 'Ride history & earnings':
          // earnings are a driver-only concept. Asserting the exact string keeps
          // it greppable instead of accidental.
          expect(item.label, 'History');
        } else {
          // Asserting the other four against the canonical copy is what stops a
          // second override creeping in unnoticed.
          expect(item.label, item.destination.label, reason: item.id);
        }
      }
    });
  });
}
