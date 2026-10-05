import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../config.dart';
import '../../../core/auth/auth_provider.dart';

/// App info + sign-out, body-only for the `RiderShell`.
///
/// Sign-out asks for confirmation, disconnects the WS, posts `POST /auth/logout`,
/// clears local storage, and the router redirects back to `/login` — all of it
/// still owned by [authProvider], which is why this screen passes callbacks
/// rather than reaching into the session itself.
///
/// It composes the same shared [AppSettingsSection]/[AppSettingsRow]/
/// [performAppSignOut] pieces the shared `AppSettingsScreen` uses, but not that
/// widget itself: `AppSettingsScreen` ships its own `Scaffold` + `AppBar`, and
/// nesting it inside the shell's `Scaffold` would render two app bars. The shell
/// owns the chrome, so this returns the settings list as its body.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  /// Mirrors `AppSettingsScreen`'s app-info subtitle — the `v`-prefixed version
  /// joined to `companion to driver_app` by a middle dot — the exact string the
  /// existing settings suite asserts.
  String get _appSubtitle =>
      'v${ApiConfig.appVersion} \u00b7 companion to driver_app';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const gap = SizedBox(height: AppSpacing.md);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.xl),
      children: [
        AppSettingsSection(
          rows: [
            AppSettingsRow(
              leading: Icons.info_outline,
              title: 'Rider App',
              subtitle: _appSubtitle,
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
                  message: 'You will need to log in again to request rides.',
                  onSignOut: () => ref.read(authProvider.notifier).logout(),
                  onSignOutCompleted: () => context.go('/login'),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}
