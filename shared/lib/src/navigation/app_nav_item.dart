import 'package:flutter/material.dart';

import 'app_nav_destination.dart';
import 'app_nav_section.dart';

/// One rendered navigation row: a shared [destination] plus the app-owned
/// [route] it opens.
///
/// The route is a plain `String` because this package has no `go_router` and
/// must not: the rider's history lives at `/history` and the driver's at
/// `/rides-history`, and neither router puts `name:` on any `GoRoute`.
///
/// [label], [icon] and [section] are resolved here, in the constructor, so a
/// consumer never has to repeat `?? destination.label` and can never read the
/// raw override by accident. That resolution is why this constructor is **not**
/// `const`: `label ?? destination.label` reads a member off a formal parameter,
/// which is not a constant expression, so a `const` constructor would have to
/// store the overrides in private fields and resolve them in getters instead.
/// The item lists are a handful of rows built once per screen build, so the
/// lost canonicalisation buys nothing here.
///
/// There is deliberately no `isEnabled`: the driver gates `/vehicle` by
/// *omitting* the item, so a disabled-tile affordance would have no consumer.
class AppNavItem {
  AppNavItem({
    required this.destination,
    required this.route,
    String? label,
    IconData? icon,
    AppNavSection? section,
  }) : label = label ?? destination.label,
       icon = icon ?? destination.icon,
       section = section ?? destination.section,
       // An empty route would push nowhere and fail silently at tap time.
       assert(route.isNotEmpty, 'route must not be empty');

  /// Which canonical destination this row is.
  final AppNavDestination destination;

  /// App-owned route string, pushed by the app's `onItemSelected` callback.
  final String route;

  /// Resolved label: the caller's override, else the destination's canonical copy.
  final String label;

  /// Resolved icon: the caller's override, else the canonical icon. Apps do not
  /// override it — it is one of the two parity guarantees.
  final IconData icon;

  /// Resolved section: the caller's override, else the canonical group. Apps do
  /// not override it — the other parity guarantee.
  final AppNavSection section;

  /// The destination's stable id — the `Key('sidebar-item-<id>')` suffix.
  String get id => destination.id;
}
