import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app_bootstrap.dart';
import '../auth/auth_provider.dart';
import 'post_auth_route.dart';
import '../../features/auth/presentation/splash_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/auth/presentation/reset_password_screen.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/navigation/driver_shell.dart';
import '../../features/trip/presentation/trip_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/rides/presentation/rides_history_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/safety/presentation/safety_screen.dart';
import '../../features/vehicle/presentation/vehicle_screen.dart';

final _shellKey = GlobalKey<NavigatorState>();

/// Router for the driver app. Redirect rules mirror the offscreen state
/// machine in DRIVER_APP_PLAN.md §3:
/// - unauthenticated → auth screens;
/// - authenticated but role `rider` (registered, not yet a driver) → /onboarding;
/// - authenticated `driver` → /home.
final routerProvider = Provider<GoRouter>((ref) {
  // The one-time bootstrap authenticates (and restores a live trip) before any
  // route decision; passing it as `refreshListenable` re-runs `redirect` when it
  // settles, so a web reload cannot bounce on the transient default state.
  final bootstrap = ref.read(sessionBootstrapProvider);
  return GoRouter(
    navigatorKey: _shellKey,
    initialLocation: '/splash',
    refreshListenable: bootstrap,
    redirect: (context, state) => resolveRedirect(
      bootstrapComplete: bootstrap.complete,
      consumeTripRestore: bootstrap.consumeTripRestore,
      auth: ref.read(authProvider),
      location: state.matchedLocation,
    ),
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => const ResetPasswordScreen(),
      ),
      GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),
      // The five top-level sections share one Scaffold + drawer (bug #10). The
      // shell owns the AppBar/drawer; each section screen is body-only.
      ShellRoute(
        builder: (context, state, child) =>
            DriverShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/vehicle',
            builder: (context, state) => const VehicleScreen(),
          ),
          GoRoute(
            path: '/rides-history',
            builder: (context, state) => const RidesHistoryScreen(),
          ),
        ],
      ),
      // `/safety` is a pushed sub-flow from Settings, not a top-level section:
      // keep it outside the shell like `/trip` so it keeps its own back arrow
      // and gains no drawer.
      GoRoute(
        path: '/safety',
        builder: (context, state) => const SafetyScreen(),
      ),
      GoRoute(path: '/trip', builder: (context, state) => const TripScreen()),
    ],
  );
});
