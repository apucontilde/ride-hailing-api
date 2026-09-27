import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_settings_row.dart';
import 'app_settings_section.dart';
import 'app_sign_out.dart';

/// The settings screen both apps ship.
///
/// The two files this replaces were structurally identical — same `Scaffold`,
/// same `AppBar('Settings')`, same three `Card > ListTile` rows with the same
/// icons, same 12 dp gaps, same `_confirmSignOut` body — differing only in the
/// app name and one sentence of dialog copy. Both of those differences are
/// parameters here.
///
/// The app-info subtitle is **exactly** `'v$appVersion · companion to
/// $companionAppName'`: the rider's existing settings suite asserts that literal
/// string, so the middle dot, the spacing and the ordering are part of the
/// contract rather than cosmetics.
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({
    super.key,
    required this.appName,
    required this.onSignOut,
    this.appVersion,
    this.serverUrl,
    this.companionAppName,
    this.signOutMessage,
    this.onSignOutCompleted,
    this.extraSections = const [],
    this.title = 'Settings',
  });

  /// `'Rider App'` / `'Driver App'`.
  final String appName;

  /// The app's own logout.
  final Future<void> Function() onSignOut;

  /// Shown as `v<value>` in the app-info subtitle.
  final String? appVersion;

  /// Shown on the server row. Null omits the row.
  final String? serverUrl;

  /// Shown as `companion to <value>` in the app-info subtitle.
  final String? companionAppName;

  /// The one sentence of sign-out copy the two apps differ on.
  final String? signOutMessage;

  /// The app's own post-logout navigation.
  final VoidCallback? onSignOutCompleted;

  /// Extra groups appended below the defaults — where a new settings entry tile
  /// goes, so it is never a bespoke `Card > ListTile` outside this screen.
  final List<AppSettingsSection> extraSections;

  /// App bar title.
  ///
  /// Reserved: both apps take the default. A shared-only test covers it.
  final String title;

  String? get _appSubtitle {
    final parts = <String>[
      if (appVersion != null) 'v$appVersion',
      if (companionAppName != null) 'companion to $companionAppName',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: AppSpacing.md);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        children: [
          AppSettingsSection(
            rows: [
              AppSettingsRow(
                leading: Icons.info_outline,
                title: appName,
                subtitle: _appSubtitle,
              ),
            ],
          ),
          if (serverUrl != null) ...[
            gap,
            AppSettingsSection(
              rows: [
                AppSettingsRow(
                  leading: Icons.dns_outlined,
                  title: 'Server',
                  subtitle: serverUrl,
                ),
              ],
            ),
          ],
          gap,
          AppSettingsSection(
            rows: [
              AppSettingsRow(
                leading: Icons.logout,
                title: 'Sign out',
                onTap: () {
                  performAppSignOut(
                    context,
                    message: signOutMessage,
                    onSignOut: onSignOut,
                    onSignOutCompleted: onSignOutCompleted,
                  );
                },
              ),
            ],
          ),
          for (final section in extraSections) ...[gap, section],
        ],
      ),
    );
  }
}
