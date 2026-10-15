import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/features/navigation/driver_nav_items.dart';

void main() {
  group('buildDriverNavItems with the shipped defaults', () {
    test('lists exactly the five driver destinations', () {
      expect(buildDriverNavItems(), hasLength(5));
    });

    test('ids are the kebab-case strings the sidebar keys are built from', () {
      expect(
        buildDriverNavItems().map((i) => i.id),
        ['home', 'profile', 'vehicle', 'ride-history', 'settings'],
      );
    });

    test('has no duplicate ids', () {
      final ids = buildDriverNavItems().map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('routes are the driver router paths', () {
      // The rider's history is /history; the driver's is /rides-history. Routes
      // are the app-owned half of the seam.
      expect(
        buildDriverNavItems().map((i) => i.route),
        ['/home', '/profile', '/vehicle', '/rides-history', '/settings'],
      );
    });

    test('leads with the canonical home destination for both apps', () {
      final home = buildDriverNavItems().first;
      expect(home.id, 'home');
      expect(home.label, 'Home');
      expect(home.icon, Icons.home_outlined);
      expect(home.section, AppNavSection.home);
      expect(home.route, '/home');
    });

    test("the only label override is 'Ride history & earnings'", () {
      for (final item in buildDriverNavItems()) {
        if (item.destination == AppNavDestination.rideHistory) {
          // Deliberate divergence from the rider's 'History': earnings are a
          // driver-only concept.
          expect(item.label, 'Ride history & earnings');
        }
      }
    });

    test('carries /vehicle while the details surface stays gated', () {
      // Nav and gating are deliberately decoupled (driver bug #6): both the
      // sidebar and the profile card are fed from this one list, so this is the
      // shared half of the "both surfaces link to /vehicle" assertion;
      // `driver_sidebar_test.dart` and `profile_screen_test.dart` each prove it
      // for their own surface. The row's screen still renders "Coming soon"
      // while `ApiConfig.vehicleFeatureEnabled` is false — the nav entry must
      // not build a saving UI on the `GET/PUT /driver/me/vehicle` stub.
      expect(
        buildDriverNavItems().map((i) => i.route),
        contains('/vehicle'),
      );
      expect(
        buildDriverNavItems()
            .where((i) => i.destination == AppNavDestination.vehicle),
        hasLength(1),
      );
    });

    test('includeVehicle: false still omits the row (the gated case)', () {
      // The parameter keeps its `true` default solely so this shape stays
      // unit-testable; production never passes it.
      final items = buildDriverNavItems(includeVehicle: false);

      expect(items.map((i) => i.route), isNot(contains('/vehicle')));
      expect(
        items.where((i) => i.destination == AppNavDestination.vehicle),
        isEmpty,
      );
      expect(items, hasLength(4));
    });

    test('carries no payment or security destination', () {
      final destinations = buildDriverNavItems().map((i) => i.destination);
      expect(destinations, isNot(contains(AppNavDestination.payment)));
      expect(destinations, isNot(contains(AppNavDestination.security)));
    });
  });

  group('the vehicle row shape (explicit includeVehicle: true)', () {
    test('inserts /vehicle in the activity group, before ride history', () {
      final items = buildDriverNavItems(includeVehicle: true);

      expect(items.map((i) => i.id), [
        'home',
        'profile',
        'vehicle',
        'ride-history',
        'settings',
      ]);
      expect(items.map((i) => i.route), [
        '/home',
        '/profile',
        '/vehicle',
        '/rides-history',
        '/settings',
      ]);
      // Grouping is by section, so the row lands inside ACTIVITY without the list
      // having to say so.
      expect(
        items.firstWhere((i) => i.id == 'vehicle').section,
        AppNavSection.activity,
      );
      expect(
        items.firstWhere((i) => i.id == 'vehicle').icon,
        Icons.directions_car_outlined,
      );
      expect(items.firstWhere((i) => i.id == 'vehicle').label, 'Vehicle');
    });
  });
}
