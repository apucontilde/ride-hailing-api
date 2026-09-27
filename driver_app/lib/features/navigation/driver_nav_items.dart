import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';

/// The driver's sidebar destinations — the only navigation data the driver owns.
///
/// Routes are app-owned because `shared/` has no router: the driver's history
/// lives at `/rides-history` where the rider's lives at `/history`. Icons and
/// sections come from [AppNavDestination] and are never overridden here — they
/// are the parity guarantee with the rider, and `driver_nav_items_test.dart`
/// asserts each one equals the canonical value.
///
/// The single label override is `rideHistory`: this drawer says
/// `'Ride history & earnings'` where the rider's says `'History'`, because
/// earnings are a driver-only concept. Both apps' suites assert their own exact
/// string, so the divergence stays deliberate and greppable.
///
/// [includeVehicle] is a parameter rather than a hardcoded `if` so the gated case
/// is testable without fighting a `const`: `ApiConfig.vehicleFeatureEnabled` is
/// `false` while `GET/PUT /driver/me/vehicle` and the documents endpoints are
/// STUBs, and a sidebar row that opens a "coming soon" screen is worse than no
/// row at all. When the vehicle backend lands, flip the flag and the row appears
/// in both the sidebar and the profile card with no other change.
List<AppNavItem> buildDriverNavItems({
  bool includeVehicle = ApiConfig.vehicleFeatureEnabled,
}) {
  return [
    AppNavItem(
      destination: AppNavDestination.profile,
      route: '/profile',
    ),
    if (includeVehicle)
      AppNavItem(
        destination: AppNavDestination.vehicle,
        route: '/vehicle',
      ),
    AppNavItem(
      destination: AppNavDestination.rideHistory,
      label: 'Ride history & earnings',
      route: '/rides-history',
    ),
    AppNavItem(
      destination: AppNavDestination.settings,
      route: '/settings',
    ),
  ];
}
