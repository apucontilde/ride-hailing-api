import '../auth/auth_provider.dart';
import '../../features/home/data/current_ride_provider.dart';

/// The route a settled session should land on after authentication and the
/// one-shot current-ride restore.
///
/// Pure and testable: it owns only the *decision*, not the sequencing (the
/// bootstrap in [app_bootstrap.dart] performs the network work first). The
/// mapping is exactly the active-status set `GET /rides/current` returns:
///
/// - `pending` → `/driver-matching` (a match without a driver must not open the
///   active-trip sheet);
/// - `accepted` / `driver_arrived` / `in_progress` → `/active-ride`;
/// - no ride, or any status the endpoint never returns (`completed`,
///   `cancelled`, `no_driver_available`) → `/home`.
///
/// Unauthenticated always resolves to `/login`.
String resolvePostAuthRoute(AuthState auth, CurrentRideState ride) {
  if (!auth.isAuthenticated) return '/login';
  switch (ride.status) {
    case 'pending':
      return '/driver-matching';
    case 'accepted':
    case 'driver_arrived':
    case 'in_progress':
      return '/active-ride';
    default:
      return '/home';
  }
}

/// The shell section routes a reload can land on and from which an active ride
/// should win (the six `ShellRoute` sections). Flow routes pushed *during* a
/// trip (`/location-search`) are deliberately excluded so the redirect cannot
/// hijack an in-app navigation.
const Set<String> _shellSections = {
  '/home',
  '/profile',
  '/history',
  '/payment',
  '/security',
  '/settings',
};

/// The go_router `redirect` decision, factored out of `routerProvider` so it can
/// be unit-tested without mounting the full app.
///
/// While the bootstrap is unresolved **every** entry path is sent to `/splash`
/// (or kept there), so a web reload at `/#/home` can never read the default
/// unauthenticated state and bounce to `/login`. Once resolved:
///
/// - unauthenticated → `/login` (auth routes are allowed through);
/// - authenticated at `/splash` or an auth route → [resolvePostAuthRoute];
/// - authenticated with a restorable ride at a shell section → the trip route
///   wins over the deep link (reload-at-any-route restore);
/// - otherwise the location is left untouched.
///
/// Returns `null` when the location is already valid.
String? resolveRedirect({
  required bool bootstrapComplete,
  required AuthState auth,
  required CurrentRideState ride,
  required String location,
}) {
  if (!bootstrapComplete) {
    return location == '/splash' ? null : '/splash';
  }

  final isSplash = location == '/splash';
  final isAuthRoute = location.startsWith('/login') ||
      location.startsWith('/register') ||
      location.startsWith('/forgot-password');

  if (!auth.isAuthenticated) {
    if (isAuthRoute) return null;
    return '/login';
  }

  if (isSplash || isAuthRoute) {
    return resolvePostAuthRoute(auth, ride);
  }

  // An active ride wins over a deep-linked shell section on a web reload, but
  // never over a flow route pushed during the trip (e.g. destination search).
  if (ride.needsRestore && _shellSections.contains(location)) {
    return resolvePostAuthRoute(auth, ride);
  }

  return null;
}
