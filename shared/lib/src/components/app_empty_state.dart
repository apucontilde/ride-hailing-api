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
    this.description,
    this.icon,
    this.action,
    this.header,
    this.topSpacing = 160,
  });

  final String message;

  /// An optional quieter second line under [message]. The per-screen empty
  /// states this replaced carried a helper sentence, so this is where it lands.
  final String? description;

  final IconData? icon;
  final Widget? action;

  /// Optional content pinned above the empty copy inside the *same* scrollable
  /// (the driver history screen's earnings card and refresh control), so the
  /// whole surface stays a single scrollable the enclosing `RefreshIndicator`
  /// can hear. Defaults to null, which preserves every existing caller.
  final Widget? header;

  final double topSpacing;

  @override
  Widget build(BuildContext context) {
    final iconData = icon;
    final descriptionText = description;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        ?header,
        SizedBox(height: topSpacing),
        if (iconData != null)
          Icon(iconData, size: 48, color: AppColors.mutedFaint),
        if (iconData != null) const SizedBox(height: AppSpacing.md),
        Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: AppColors.muted),
          ),
        ),
        if (descriptionText != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Center(
            child: Text(
              descriptionText,
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(
                color: AppColors.mutedFaint,
              ),
            ),
          ),
        ],
        if (action != null) Center(child: action!),
      ],
    );
  }
}
