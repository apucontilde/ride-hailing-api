import 'package:flutter/material.dart';

import 'app_nav_section.dart';

/// The single source of truth for a destination's id, canonical label, icon and
/// section.
///
/// A destination's *route* is app-owned (`/history` in the rider, `/rides-history`
/// in the driver) but its identity is not: both apps name "the same place" the
/// same way, which is what stops the drift this enum was extracted from — the
/// rider's sidebar called `/payment` `Icons.payment` while its own profile card
/// called the same destination `Icons.credit_card`.
///
/// [id] is kebab-case and is a **test contract**, not an implementation detail:
/// `Key('sidebar-item-<id>')` renders it and both apps' nav-item suites assert
/// the exact id lists.
enum AppNavDestination {
  profile('profile', 'Profile', Icons.person_outline, AppNavSection.account),
  rideHistory(
    'ride-history',
    'Ride history',
    Icons.history,
    AppNavSection.activity,
  ),
  payment('payment', 'Payment', Icons.payment, AppNavSection.activity),
  vehicle(
    'vehicle',
    'Vehicle',
    Icons.directions_car_outlined,
    AppNavSection.activity,
  ),
  security('security', 'Security', Icons.shield_outlined, AppNavSection.safety),
  settings(
    'settings',
    'Settings',
    Icons.settings_outlined,
    AppNavSection.app,
  );

  const AppNavDestination(this.id, this.label, this.icon, this.section);

  /// Stable kebab-case identifier, also the sidebar item's test key suffix.
  final String id;

  /// Canonical copy. This is the *default* for any consumer, not a mandate:
  /// both apps deliberately override `rideHistory` (the rider says `'History'`,
  /// the driver says `'Ride history & earnings'` because earnings are a
  /// driver-only concept) and each app's suite asserts its own exact string, so
  /// the divergence stays greppable instead of accidental.
  final String label;

  /// Canonical icon. Never overridden by an app — it is one of the two parity
  /// guarantees (with [section]).
  final IconData icon;

  /// Canonical group. Never overridden by an app.
  final AppNavSection section;
}
