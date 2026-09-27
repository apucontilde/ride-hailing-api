import 'package:flutter/material.dart';

/// One sidebar row.
///
/// The icon is an explicit `Icon(size: 22)` rather than a
/// `ListTileThemeData.iconSize`, because no such property exists — `ListTileThemeData`
/// has `iconColor` but no size. 22 is what both apps' hand-rolled rows hardcoded.
///
/// The `key` is supplied by `AppSidebar` as `Key('sidebar-item-<id>')` so tests
/// can find a row without string-matching its label — which matters because the
/// two apps deliberately override `rideHistory`'s label differently.
class AppSidebarItem extends StatelessWidget {
  const AppSidebarItem({
    super.key,
    required this.leading,
    required this.label,
    this.trailing,
    this.selected = false,
    this.onTap,
  });

  /// Row icon, rendered at 22 dp.
  final IconData leading;

  /// Row text.
  final String label;

  /// Optional trailing widget (a chevron, a badge).
  final Widget? trailing;

  /// Whether this row is the current destination.
  final bool selected;

  /// Row tap. Navigation stays app-side.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(leading, size: 22),
      title: Text(label),
      trailing: trailing,
      selected: selected,
      onTap: onTap,
    );
  }
}
