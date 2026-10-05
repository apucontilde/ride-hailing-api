import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../core/auth/auth_provider.dart';
import 'rider_nav_items.dart';

/// The one `Scaffold` that wraps every top-level rider section.
///
/// GoRouter's [ShellRoute] builds this around `/home`, `/profile`, `/history`,
/// `/payment`, `/security` and `/settings`, so the [AppSidebar] is constructed
/// exactly once and every section shares it. The section screens are body-only
/// (`HomeScreen` included); this widget owns the chrome:
///
/// - `drawer:` the single [AppSidebar], with the account header and the sign-out
///   footer, and `selectedRoute` wired from the current location so the active
///   section is highlighted (`AppSidebar.selectedRoute` finally has a consumer).
/// - `appBar:` the sidebar toggle leading + a route-aware title. `/home` is the
///   exception: it is an edge-to-edge map with no `AppBar`, so it keeps its own
///   `Positioned` [AppSidebarToggleButton] over the map. Because the shell owns
///   the only `Scaffold`, that overlay's `Scaffold.of(context)` resolves here and
///   opens the same drawer.
///
/// Flow routes (`/location-search`, `/driver-matching`, `/active-ride`) and the
/// auth routes are deliberately **outside** the shell: they keep their own chrome.
class RiderShell extends ConsumerWidget {
  const RiderShell({super.key, required this.state, required this.child});

  /// The matched [ShellRoute] state; `state.uri.path` drives the title and the
  /// highlighted sidebar row.
  final GoRouterState state;

  /// The matched section screen, rendered as the shell body.
  final Widget child;

  /// Section route → `AppBar` title. `/home` is absent on purpose: it has no bar.
  static const Map<String, String> _sectionTitles = {
    '/profile': 'Profile',
    '/history': 'Ride History',
    '/payment': 'Payment',
    '/security': 'Security',
    '/settings': 'Settings',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = state.uri.path;
    final isHome = path == '/home';
    final profile = ref.watch(riderProfileProvider);
    final email = ref.watch(authProvider).user?.email ?? '';
    // The rider's own name, falling back to their email. Seeded by the auth
    // bootstrap from `GET /rider/me`; empty only before the first fetch lands.
    final name = profile?.fullName.isNotEmpty == true
        ? profile!.fullName
        : email;

    return Scaffold(
      drawer: AppSidebar(
        items: buildRiderNavItems(),
        // The rider shows no status dot and no rating, so `statusLabel` and
        // `ratingLabel` stay null and the header renders the email line.
        // `photoUrl` is passed raw: `RiderProfile` already normalises `'' → null`
        // and the shared header treats null and blank identically anyway.
        account: AppSidebarAccount(
          displayName: name,
          secondaryLine: email.isEmpty ? null : email,
          photoUrl: profile?.photoUrl,
        ),
        selectedRoute: path,
        onAccountPressed: () {
          closeSidebar(context);
          context.go('/profile');
        },
        onItemSelected: (item) {
          closeSidebar(context);
          context.go(item.route);
        },
        footer: AppSidebarFooter(
          message: 'You will need to log in again to request rides.',
          onSignOut: () => ref.read(authProvider.notifier).logout(),
          onSignOutCompleted: () => context.go('/login'),
        ),
      ),
      appBar: isHome
          ? null
          : AppBar(
              leading: const AppSidebarToggleButton(),
              title: Text(_sectionTitles[path] ?? ''),
            ),
      body: child,
    );
  }
}
