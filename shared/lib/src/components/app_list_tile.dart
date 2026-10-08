import 'package:flutter/material.dart';

/// The shared list-row look.
///
/// A parameterized `ListTile` wrapper: screens that need the common
/// icon/title/subtitle/trailing shape use this instead of re-deriving padding
/// and density per file.
class AppListTile extends StatelessWidget {
  const AppListTile({
    super.key,
    required this.title,
    this.leading,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.dense,
    this.contentPadding,
  });

  final Widget title;
  final Widget? leading;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap,
      dense: dense,
      contentPadding: contentPadding,
    );
  }
}
