import 'package:flutter/material.dart';

/// One settings row's data.
///
/// A value object, not a widget: `AppSettingsSection` renders its rows so a
/// group is one `Card` and the rows inside it cannot disagree about padding or
/// dividers.
///
/// The defaults reproduce the three rows both apps ship today — an info row, a
/// server row and a sign-out row — so an app that passes only `appName`,
/// `appVersion` and `serverUrl` renders exactly what it rendered before.
class AppSettingsRow {
  const AppSettingsRow({
    required this.title,
    this.leading,
    this.subtitle,
    this.onTap,
    this.isDestructive = false,
    this.trailing,
  });

  /// Row text.
  final String title;

  /// Row icon.
  final IconData? leading;

  /// Second line.
  final String? subtitle;

  /// Tap handler. Null makes the row inert, which is what the two info rows are.
  final VoidCallback? onTap;

  /// Renders the icon and title in the theme's error colour.
  ///
  /// Reserved: neither app passes it yet — today's settings sign-out row is
  /// default-coloured, and the sidebar's own footer does its own destructive
  /// styling. Covered by a shared-only test so it cannot rot.
  final bool isDestructive;

  /// Overrides the row's trailing slot (a chevron, a switch).
  ///
  /// Reserved, like [isDestructive]: no app passes it yet, and a shared-only test
  /// proves it renders.
  final Widget? trailing;
}
