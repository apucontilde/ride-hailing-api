import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A full-area empty state: an optional icon, a message, an optional action.
///
/// Renders a scrollable `ListView` so it drops straight into a
/// `RefreshIndicator` body (the rider history screen) and always stays
/// pull-to-refreshable even when empty. `topSpacing` reproduces the history
/// screen's 160 dp lead-in.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.message,
    this.icon,
    this.action,
    this.topSpacing = 160,
  });

  final String message;
  final IconData? icon;
  final Widget? action;
  final double topSpacing;

  @override
  Widget build(BuildContext context) {
    final iconData = icon;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: topSpacing),
        if (iconData != null) Icon(iconData, size: 48, color: AppColors.mutedFaint),
        if (iconData != null) const SizedBox(height: AppSpacing.md),
        Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: AppColors.muted),
          ),
        ),
        if (action != null) Center(child: action!),
      ],
    );
  }
}
