import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A section heading, with an optional trailing widget.
class AppSectionHeader extends StatelessWidget {
  const AppSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding,
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Row(
        children: [
          Expanded(child: Text(title, style: AppTextStyles.title)),
          ?trailing,
        ],
      ),
    );
  }
}
