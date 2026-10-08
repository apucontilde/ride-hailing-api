import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// A full-area error state: icon + message + optional retry.
///
/// A scrollable `ListView`, like [AppEmptyState], so it can sit directly under
/// a `RefreshIndicator`.
class AppErrorState extends StatelessWidget {
  const AppErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
    this.icon = Icons.error_outline,
    this.topSpacing = 160,
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;
  final double topSpacing;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: topSpacing),
        Icon(icon, size: 48, color: AppColors.mutedFaint),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: AppColors.muted),
          ),
        ),
        if (onRetry != null)
          Center(
            child: TextButton(onPressed: onRetry, child: Text(retryLabel)),
          ),
      ],
    );
  }
}

/// A one-line error row: icon + message + optional retry, for inline surfaces
/// (the Home route-info row, the driver history error row).
class AppErrorRow extends StatelessWidget {
  const AppErrorRow({
    super.key,
    required this.message,
    this.onRetry,
    this.retryLabel = 'Retry',
    this.icon = Icons.error_outline,
    this.iconSize = 16,
  });

  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  final IconData icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: iconSize, color: AppColors.danger),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: AppTextStyles.body.copyWith(color: AppColors.danger),
          ),
        ),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: Text(retryLabel)),
      ],
    );
  }
}
