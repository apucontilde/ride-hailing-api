import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/config.dart';
import 'package:driver_app/features/navigation/driver_nav_items.dart';

void main() {
  group('buildDriverNavItems with the shipped flag', () {
    test('the flag is false, so the gate below is the real behaviour', () {
      // If this ever flips, the vehicle assertions here must move to the
      // includeVehicle: true expectations rather than be deleted.
      expect(ApiConfig.vehicleFeatureEnabled, isFalse);
    });

    test('lists exactly the three driver destinations', () {
      expect(buildDriverNavItems(), hasLength(3));
    });

    test('ids are the kebab-case strings the sidebar keys are built from', () {
      expect(
        buildDriverNavItems().map((i) => i.id),
        ['profile', 'ride-history', 'settings'],
      );
    });

    test('has no duplicate ids', () {
      final ids = buildDriverNavItems().map((i) => i.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
    });

    test('sections are the canonical groups, in order', () {
      expect(
        buildDriverNavItems().map((i) => i.section),
        [AppNavSection.account, AppNavSection.activity, AppNavSection.app],
      );
    });

    test('routes are the driver router paths', () {
      // The rider's history is /history; the driver's is /rides-history. Routes
      // are the app-owned half of the seam.
      expect(
        buildDriverNavItems().map((i) => i.route),
        ['/profile', '/rides-history', '/settings'],
      );
    });

    test('every icon is the canonical one', () {
      expect(
        buildDriverNavItems().map((i) => i.icon),
        [Icons.person_outline, Icons.history, Icons.settings_outlined],
      );
      for (final item in buildDriverNavItems()) {
        expect(item.icon, item.destination.icon, reason: item.id);
      }
    });

    test("the only label override is 'Ride history & earnings'", () {
      for (final item in buildDriverNavItems()) {
        if (item.destination == AppNavDestination.rideHistory) {
          // Deliberate divergence from the rider's 'History': earnings are a
          // driver-only concept.
          expect(item.label, 'Ride history & earnings');
        } else {
          expect(item.label, item.destination.label, reason: item.id);
        }
      }
    });

    test('carries no /vehicle route while the vehicle backend is a stub', () {
      // Both the sidebar and the profile card are fed from this one list, so this
      // is the shared half of the "neither surface links to /vehicle" assertion;
      // `driver_sidebar_test.dart` and `profile_screen_test.dart` each prove it
      // for their own surface. `/vehicle` is therefore reachable only by deep
      // link, which is driver known bug #12 re-scoped rather than fixed.
      expect(
        buildDriverNavItems().map((i) => i.route),
        isNot(contains('/vehicle')),
      );
      expect(
        buildDriverNavItems().where((i) => i.destination == AppNavDestination.vehicle),
        isEmpty,
      );
    });

    test('carries no payment or security destination', () {
      final destinations = buildDriverNavItems().map((i) => i.destination);
      expect(destinations, isNot(contains(AppNavDestination.payment)));
      expect(destinations, isNot(contains(AppNavDestination.security)));
    });
  });

  group('buildDriverNavItems with the vehicle gate open', () {
    test('inserts /vehicle in the activity group, before ride history', () {
      final items = buildDriverNavItems(includeVehicle: true);

      expect(items.map((i) => i.id), [
        'profile',
        'vehicle',
        'ride-history',
        'settings',
      ]);
      expect(items.map((i) => i.route), [
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

    test('the parameter is what makes the gated case testable', () {
      // `ApiConfig.vehicleFeatureEnabled` is a const, so without the parameter a
      // suite could only ever exercise whichever branch the flag happens to be.
      expect(buildDriverNavItems(includeVehicle: false), hasLength(3));
      expect(buildDriverNavItems(includeVehicle: true), hasLength(4));
    });
  });
}
