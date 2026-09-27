import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../config.dart';
import '../../../core/auth/auth_provider.dart';

/// App info + sign-out, rendered by the shared [AppSettingsScreen].
///
/// Sign-out asks for confirmation, disconnects the WS, posts `POST /auth/logout`,
/// clears local storage, and the router redirects back to `/login` — all of it
/// still owned by [authProvider], which is why this screen passes callbacks
/// rather than reaching into the session itself.
///
/// Mirrors `driver_app/lib/features/settings/presentation/settings_screen.dart`;
/// the two used to be structurally identical files differing only in the app name
/// and one sentence of dialog copy, and both of those are now parameters. It also
/// absorbed the old `/about` stub, which only ever said "About this app" and is
/// now the app-info card.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppSettingsScreen(
      appName: 'Rider App',
      appVersion: ApiConfig.appVersion,
      serverUrl: ApiConfig.baseUrl,
      companionAppName: 'driver_app',
      signOutMessage: 'You will need to log in again to request rides.',
      onSignOut: () => ref.read(authProvider.notifier).logout(),
      onSignOutCompleted: () => context.go('/login'),
    );
  }
}
