import '../auth/auth_provider.dart';

/// The go_router `redirect` decision for the driver app, factored out of
/// `routerProvider` so it can be unit-tested without mounting the full app.
///
/// While the session bootstrap is unresolved **every** entry path is sent to
/// `/splash` (or kept there), so a web reload at `/#/trip` can never read the
/// default unauthenticated state and bounce to `/login`
/// (`driver_app_plans/[auth]_web_reload_session_bootstrap.md`).
///
/// Once resolved, a restored live trip wins **once** over the reloaded route
/// (`driver_app_plans/01_[trip]_post_auth_live_trip_restore.md`): the first
/// redirect after a restore consumes the one-shot flag and sends the driver to
/// `/trip`. Afterwards the flag is clear, so leaving `/trip` is never trapped.
/// The remaining rules mirror the offscreen state machine in `DRIVER_APP_PLAN.md`
/// §3:
/// - unauthenticated → auth screens;
/// - authenticated but role `rider` (registered, not yet a driver) → /onboarding;
/// - authenticated `driver` → /home.
///
/// Returns `null` when the location is already valid.
String? resolveRedirect({
  required bool bootstrapComplete,
  required bool Function() consumeTripRestore,
  required AuthState auth,
  required String location,
}) {
  if (!bootstrapComplete) {
    return location == '/splash' ? null : '/splash';
  }

  // One-shot live-trip restore. Consume unconditionally so a reload that is
  // already parked on /trip cannot leave the flag armed to re-trap the driver
  // on a later pop to /home.
  final restoreTrip = consumeTripRestore();
  if (restoreTrip && location != '/trip') return '/trip';

  final isSplash = location == '/splash';
  final isAuthRoute = location == '/login' ||
      location == '/register' ||
      location == '/forgot-password' ||
      location == '/reset-password';
  final isOnboarding = location == '/onboarding';

  if (!auth.isAuthenticated) return isAuthRoute ? null : '/login';
  // Authenticated but not yet a driver → force onboarding.
  if (!auth.isDriver && !isOnboarding) return '/onboarding';
  if (!auth.isDriver && isAuthRoute) return '/onboarding';
  if (auth.isDriver && (isAuthRoute || isOnboarding || isSplash)) {
    return '/home';
  }
  return null;
}
