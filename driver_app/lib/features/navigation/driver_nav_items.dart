import 'package:ride_hailing_shared/ride_hailing_shared.dart';

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
/// [includeVehicle] defaults to `true`: the vehicle row is **unconditional**
/// (driver bug #6) — both surfaces that read this list, the drawer
/// (`DriverShell`) and the profile card, link to `/vehicle`, so the section is
/// no longer deep-link-only. What stays gated is the *screen's* details/save
/// half: `ApiConfig.vehicleFeatureEnabled` (still `false` while `GET/PUT
/// /driver/me/vehicle` and `GET/POST /driver/me/documents` are backend stubs)
/// picks `_ComingSoon` over `_VehicleDetails` inside `VehicleScreen`, so the nav
/// entry never grows a saving UI on a stub. The parameter keeps its `true`
/// default solely so the omitted-row case stays unit-testable.
List<AppNavItem> buildDriverNavItems({
  bool includeVehicle = true,
}) {
  return [
    AppNavItem(
      destination: AppNavDestination.home,
      route: '/home',
    ),
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
