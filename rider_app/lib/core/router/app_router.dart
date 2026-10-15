import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../app_bootstrap.dart';
import '../auth/auth_provider.dart';
import '../../features/home/data/current_ride_provider.dart';
import 'post_auth_route.dart';
import '../../features/auth/presentation/splash_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/register_screen.dart';
import '../../features/auth/presentation/forgot_password_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/home/presentation/location_search_screen.dart';
import '../../features/home/presentation/driver_matching_screen.dart';
import '../../features/home/presentation/active_ride_screen.dart';
import '../../features/home/presentation/profile_screen.dart';
import '../../features/home/presentation/history_screen.dart';
import '../../features/home/presentation/payment_screen.dart';
import '../../features/home/presentation/security_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/navigation/rider_shell.dart';

final _shellKey = GlobalKey<NavigatorState>();

/// Test seam: where the router boots. Production is `/splash`; a widget test
/// overrides it with a shell location (e.g. `/home`) to reproduce a browser
/// reload, where go_router boots at the reloaded hash URL rather than `/splash`.
final routerInitialLocationProvider = Provider<String>((ref) => '/splash');

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _shellKey,
    initialLocation: ref.read(routerInitialLocationProvider),
    // Re-run `redirect` once the async bootstrap settles, even though the
    // bootstrap itself triggers no navigation.
    refreshListenable: ref.read(sessionBootstrapProvider),
    redirect: (context, state) => resolveRedirect(
      bootstrapComplete: ref.read(sessionBootstrapProvider).complete,
      auth: ref.read(authProvider),
      ride: ref.read(currentRideProvider),
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
      // The six top-level sections share one shell: one `Scaffold`, one
      // `AppSidebar`, one toggle. Flow routes below stay outside it.
      ShellRoute(
        builder: (context, state, child) =>
            RiderShell(state: state, child: child),
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
            path: '/history',
            builder: (context, state) => const HistoryScreen(),
          ),
          GoRoute(
            path: '/payment',
            builder: (context, state) => const PaymentScreen(),
          ),
          GoRoute(
            path: '/security',
            builder: (context, state) => const SecurityScreen(),
          ),
          // Absorbs the old `/about` stub; see settings_screen.dart.
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/location-search',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return LocationSearchScreen(
            hint: extra?['hint'] as String? ?? 'Search destinations...',
            lat: extra?['lat'] as double?,
            lng: extra?['lng'] as double?,
          );
        },
      ),
      GoRoute(
        path: '/driver-matching',
        builder: (context, state) => const DriverMatchingScreen(),
      ),
      GoRoute(
        path: '/active-ride',
        builder: (context, state) => const ActiveRideScreen(),
      ),
    ],
  );
});
