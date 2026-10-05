import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../../core/auth/auth_provider.dart';
import '../profile/providers/profile_notifier.dart';
import 'driver_nav_items.dart';

/// Chrome shared by the driver's five top-level sections (bug #10).
///
/// Installed as the `ShellRoute.builder` in `app_router.dart`, so `/home`,
/// `/profile`, `/settings`, `/vehicle` and `/rides-history` all render inside
/// the one [Scaffold] this builds. That is what makes the single [AppSidebar]
/// reachable from every section: [AppSidebarToggleButton] calls
/// `Scaffold.of(context).openDrawer()`, and the nearest `Scaffold` above it is
/// this one, wherever the section content came from.
///
/// `/trip` and `/safety` deliberately stay outside: `/trip` owns its terminal
/// `PopScope` handling and is pushed mid-journey, and `/safety` is a pushed
/// sub-flow, so neither should gain a drawer or lose its back affordance.
///
/// The section screens are body-only by construction — they no longer build a
/// `Scaffold` — because a second `Scaffold` here would put a drawer-less AppBar
/// under this one and send the toggle's `Scaffold.of` to the wrong place.
class DriverShell extends ConsumerWidget {
  const DriverShell({super.key, required this.location, required this.child});

  /// The current section's matched location, used to pick the AppBar title.
  ///
  /// Passed in rather than read from `GoRouterState` so the shell can be pumped
  /// directly in tests; the `ShellRoute.builder` already has `state`.
  final String location;

  /// The section screen for [location].
  final Widget child;

  /// Route → AppBar title. The five keys mirror the routes the `ShellRoute`
  /// wraps; anything else falls back to a neutral title.
  static const Map<String, String> sectionTitles = {
    '/home': 'Home',
    '/profile': 'Profile',
    '/settings': 'Settings',
    '/vehicle': 'Vehicle & Documents',
    '/rides-history': 'Ride History',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(driverProfileProvider);
    final name = driver?.fullName.isNotEmpty == true
        ? driver!.fullName
        : 'Driver';
    // The sidebar header shows the same rating the profile screen does.
    final ratingLabel = ref
        .read(profileNotifierProvider.notifier)
        .ratingSummaryLabel;

    return Scaffold(
      appBar: AppBar(
        // The same button widget the rider uses, instead of Flutter's implicit
        // hamburger, so both apps open the sidebar identically.
        leading: const AppSidebarToggleButton(),
        title: Text(sectionTitles[location] ?? 'Driver'),
      ),
      drawer: AppSidebar(
        items: buildDriverNavItems(),
        // Highlights the active section, matching the rider shell. `location`
        // is the shell's matched section path; without this the drawer opened
        // from any section with no row marked current.
        selectedRoute: location,
        account: AppSidebarAccount(
          displayName: name,
          statusLabel: driver?.status,
          statusColor: driver?.isOnline == true ? Colors.green : Colors.grey,
          photoUrl: driver?.photoUrl,
          ratingLabel: ratingLabel,
        ),
        // The header was inert before — no details affordance, no wrapping tap
        // target — so this is new behaviour, and it pops before navigating.
        onAccountPressed: () {
          closeSidebar(context);
          context.go('/profile');
        },
        onItemSelected: (item) {
          closeSidebar(context);
          // `go`, not `push`: the five destinations are top-level siblings, so
          // selecting one replaces the current section instead of stacking it.
          // It also keeps the shell's `location` (and thus the title) fresh:
          // an imperative `push` leaves the shell match's location stale.
          context.go(item.route);
        },
        footer: AppSidebarFooter(
          message: 'You will need to log in again to accept ride requests.',
          onSignOut: () => ref.read(authProvider.notifier).logout(),
          onSignOutCompleted: () => context.go('/login'),
        ),
      ),
      body: child,
    );
  }
}
