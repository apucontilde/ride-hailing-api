import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../config.dart';
import '../../../core/auth/auth_provider.dart';

/// Sign out + app info (DRIVER_APP_PLAN.md M10), composed from the shared
/// `AppSettingsSection` / `AppSettingsRow` widgets and `performAppSignOut`.
///
/// Sign-out asks for confirmation, disconnects the WS, posts `POST /auth/logout`,
/// clears local storage, and the router redirects back to /login — all of it
/// still owned by [authProvider], which is why this screen passes callbacks
/// rather than reaching into the session itself.
///
/// Body-only since bug #10: `DriverShell` owns the one Scaffold/AppBar, so this
/// screen cannot delegate to the shared `AppSettingsScreen`, which hardcodes its
/// own Scaffold. The rows below stay byte-for-byte the shared screen's
/// composition (including the app-info subtitle) so the two cannot drift.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Body-only: `DriverShell` owns the Scaffold/AppBar for the section, so
    // this screen composes the same shared rows as `AppSettingsScreen` without
    // its Scaffold. (`AppSettingsScreen` hardcodes one and lives in `shared/`,
    // which the driver may not modify — see the plan's shell decision.)
    const gap = SizedBox(height: AppSpacing.md);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        AppSettingsSection(
          rows: [
            AppSettingsRow(
              leading: Icons.info_outline,
              title: 'Driver App',
              subtitle: 'v${ApiConfig.appVersion} · companion to rider_app',
            ),
          ],
        ),
        gap,
        AppSettingsSection(
          rows: [
            AppSettingsRow(
              leading: Icons.dns_outlined,
              title: 'Server',
              subtitle: ApiConfig.baseUrl,
            ),
          ],
        ),
        gap,
        AppSettingsSection(
          rows: [
            AppSettingsRow(
              leading: Icons.logout,
              title: 'Sign out',
              onTap: () {
                performAppSignOut(
                  context,
                  message:
                      'You will need to log in again to accept ride requests.',
                  onSignOut: () => ref.read(authProvider.notifier).logout(),
                  onSignOutCompleted: () => context.go('/login'),
                );
              },
            ),
          ],
        ),
        gap,
        AppSettingsSection(
          rows: [
            AppSettingsRow(
              leading: Icons.health_and_safety_outlined,
              title: 'Safety & support',
              subtitle: 'Emergency SOS & feedback',
              onTap: () => context.push('/safety'),
            ),
          ],
        ),
      ],
    );
  }
}
