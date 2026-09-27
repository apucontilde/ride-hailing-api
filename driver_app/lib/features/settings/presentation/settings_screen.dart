import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../config.dart';
import '../../../core/auth/auth_provider.dart';

/// Sign out + app info (DRIVER_APP_PLAN.md M10), rendered by the shared
/// [AppSettingsScreen].
///
/// Sign-out asks for confirmation, disconnects the WS, posts `POST /auth/logout`,
/// clears local storage, and the router redirects back to /login — all of it
/// still owned by [authProvider], which is why this screen passes callbacks
/// rather than reaching into the session itself.
///
/// Structurally identical to the rider's settings screen and differing only in
/// the app name and one sentence of dialog copy, both of which are parameters
/// now, so the two no longer have to be kept in step by hand.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppSettingsScreen(
      appName: 'Driver App',
      appVersion: ApiConfig.appVersion,
      serverUrl: ApiConfig.baseUrl,
      companionAppName: 'rider_app',
      signOutMessage: 'You will need to log in again to accept ride requests.',
      onSignOut: () => ref.read(authProvider.notifier).logout(),
      onSignOutCompleted: () => context.go('/login'),
    );
  }
}
