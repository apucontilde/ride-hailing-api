import 'package:flutter/material.dart';

import '../settings/app_sign_out.dart';

/// The pinned sidebar footer both apps use for sign-out.
///
/// Sign-out used to cost three taps in the rider (sidebar → Settings → Sign out)
/// and two in the driver; this makes it one from anywhere the sidebar is open.
/// The `/settings` screen keeps its own sign-out row — both apps agree on that.
///
/// Owns the destructive styling and the ordering, and delegates the flow to
/// [performAppSignOut], so session state stays app-owned. The callback names are
/// the same ones `AppSettingsScreen` takes; the footer does not rename them.
class AppSidebarFooter extends StatelessWidget {
  const AppSidebarFooter({
    super.key,
    required this.onSignOut,
    this.onSignOutCompleted,
    this.message,
  });

  /// The app's own logout.
  final Future<void> Function() onSignOut;

  /// The app's own post-logout navigation.
  final VoidCallback? onSignOutCompleted;

  /// Confirmation copy, which is the one sentence the two apps differ on.
  final String? message;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          ListTile(
            key: const Key('sidebar-sign-out'),
            leading: Icon(Icons.logout, color: color),
            title: Text('Sign out', style: TextStyle(color: color)),
            onTap: () {
              performAppSignOut(
                context,
                message: message,
                onSignOut: onSignOut,
                onSignOutCompleted: onSignOutCompleted,
              );
            },
          ),
        ],
      ),
    );
  }
}
