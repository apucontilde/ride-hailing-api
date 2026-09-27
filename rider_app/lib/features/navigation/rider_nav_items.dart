import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// The rider's sidebar destinations — the only navigation data the rider owns.
///
/// The routes are app-owned because `shared/` has no router and must not: the
/// rider's history lives at `/history` where the driver's lives at
/// `/rides-history`. Icons and sections come from [AppNavDestination] and are
/// never overridden here — they are the parity guarantee with the driver, and
/// `rider_nav_items_test.dart` asserts each one equals the canonical value.
///
/// The single override is `rideHistory`'s label: this drawer has always said
/// `'History'` where the driver's says `'Ride history & earnings'` (earnings are
/// a driver-only concept). Both apps' suites assert their own exact string, so
/// the divergence stays deliberate and greppable instead of accidental.
///
/// Both the sidebar and the profile screen's [AppNavLinkCard] are fed from this
/// one list, which is what stops them disagreeing about an icon or a label — the
/// drawer used to call `/payment` `Icons.payment` while the card called the same
/// destination `Icons.credit_card`.
List<AppNavItem> buildRiderNavItems() => [
      AppNavItem(
        destination: AppNavDestination.profile,
        route: '/profile',
      ),
      AppNavItem(
        destination: AppNavDestination.rideHistory,
        label: 'History',
        route: '/history',
      ),
      AppNavItem(
        destination: AppNavDestination.payment,
        route: '/payment',
      ),
      AppNavItem(
        destination: AppNavDestination.security,
        route: '/security',
      ),
      AppNavItem(
        destination: AppNavDestination.settings,
        route: '/settings',
      ),
    ];
