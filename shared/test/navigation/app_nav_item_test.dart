import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('AppNavDestination', () {
    test('ids are the kebab-case strings the sidebar keys are built from', () {
      // Both apps' nav-item suites assert `Key('sidebar-item-<id>')` against
      // these exact strings, so a camelCase id here turns them red for a reason
      // no analyzer will report.
      expect(
        AppNavDestination.values.map((d) => d.id),
        ['profile', 'ride-history', 'payment', 'vehicle', 'security', 'settings'],
      );
    });

    test('canonical labels, icons and sections are the parity defaults', () {
      expect(AppNavDestination.profile.label, 'Profile');
      expect(AppNavDestination.profile.icon, Icons.person_outline);
      expect(AppNavDestination.profile.section, AppNavSection.account);

      expect(AppNavDestination.rideHistory.label, 'Ride history');
      expect(AppNavDestination.rideHistory.icon, Icons.history);
      expect(AppNavDestination.rideHistory.section, AppNavSection.activity);

      expect(AppNavDestination.payment.icon, Icons.payment);
      expect(AppNavDestination.payment.section, AppNavSection.activity);

      expect(AppNavDestination.vehicle.icon, Icons.directions_car_outlined);
      expect(AppNavDestination.vehicle.section, AppNavSection.activity);

      expect(AppNavDestination.security.icon, Icons.shield_outlined);
      expect(AppNavDestination.security.section, AppNavSection.safety);

      expect(AppNavDestination.settings.icon, Icons.settings_outlined);
      expect(AppNavDestination.settings.section, AppNavSection.app);
    });
  });

  group('AppNavSection', () {
    test('headings are the four fixed groups, in render order', () {
      expect(
        AppNavSection.values.map((s) => s.title),
        ['ACCOUNT', 'ACTIVITY', 'SAFETY', 'APP'],
      );
    });
  });

  group('AppNavItem', () {
    test('inherits id, label, icon and section from its destination', () {
      final item = AppNavItem(
        destination: AppNavDestination.payment,
        route: '/payment',
      );

      expect(item.id, 'payment');
      expect(item.label, 'Payment');
      expect(item.icon, Icons.payment);
      expect(item.section, AppNavSection.activity);
      expect(item.route, '/payment');
    });

    test('a label override wins over the canonical label', () {
      // The one override both apps actually use: the rider says 'History', the
      // driver says 'Ride history & earnings'.
      final item = AppNavItem(
        destination: AppNavDestination.rideHistory,
        label: 'Ride history & earnings',
        route: '/rides-history',
      );

      expect(item.label, 'Ride history & earnings');
      // The override changes the copy, not the identity.
      expect(item.id, 'ride-history');
      expect(item.icon, Icons.history);
      expect(item.section, AppNavSection.activity);
    });

    test('icon and section overrides win', () {
      // No app passes these — they are the parity guarantees — but the contract
      // says an override is honoured rather than silently dropped, so a consumer
      // that ever needs one is not fighting the widget.
      final item = AppNavItem(
        destination: AppNavDestination.payment,
        icon: Icons.credit_card,
        section: AppNavSection.safety,
        route: '/payment',
      );

      expect(item.icon, Icons.credit_card);
      expect(item.section, AppNavSection.safety);
      expect(item.label, 'Payment');
    });

    test('an empty route is rejected rather than failing silently on tap', () {
      expect(
        () => AppNavItem(destination: AppNavDestination.profile, route: ''),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
