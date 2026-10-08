import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The shared status chip (the driver's ride-status pill, the rider's active
/// trip status).
///
/// Defaults to the info tint/foreground; pass [color]/[background] for another
/// role (e.g. `AppColors.success`).
class AppStatusChip extends StatelessWidget {
  const AppStatusChip({
    super.key,
    required this.label,
    this.color,
    this.background,
    this.icon,
  });

  final String label;
  final Color? color;
  final Color? background;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: icon == null ? null : Icon(icon, size: 16, color: color),
      label: Text(label),
      backgroundColor: background ?? AppColors.infoTint,
      labelStyle: TextStyle(
        color: color ?? AppColors.infoForeground,
        fontSize: 12,
      ),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// A small status badge: a coloured dot and a label (the driver's availability
/// dot).
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.label,
    this.color,
    this.dotSize = 10,
  });

  final String label;
  final Color? color;
  final double dotSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: dotSize,
          height: dotSize,
          decoration: BoxDecoration(
            color: color ?? AppColors.success,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(label, style: AppTextStyles.label),
      ],
    );
  }
}
