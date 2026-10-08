import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The shared button variants.
enum AppButtonVariant {
  /// A filled, high-emphasis action (Material `ElevatedButton`).
  primary,

  /// An outlined, medium-emphasis action (Material `OutlinedButton`).
  secondary,

  /// A destructive action.
  danger,

  /// A low-emphasis text action.
  text,
}

/// The one button both apps build.
///
/// [AppButtonVariant.primary] renders an `ElevatedButton` on purpose: the rider
/// tests locate the submit/request actions with
/// `find.widgetWithText(ElevatedButton, …)`, so the Material widget must remain
/// in the tree. All variants inherit the shared shape/size from `AppTheme.light`
/// and tint from [AppColors].
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.isLoading = false,
    this.expand = false,
  });

  /// Button text.
  final String label;

  /// Tap handler; `null` disables the button.
  final VoidCallback? onPressed;

  /// Visual role.
  final AppButtonVariant variant;

  /// Optional leading icon. Replaced by the spinner while [isLoading].
  final IconData? icon;

  /// Swaps the content for a small spinner and disables the button.
  final bool isLoading;

  /// Wraps the button in a full-width `SizedBox`.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final spinnerColor = variant == AppButtonVariant.danger
        ? AppColors.onPrimary
        : null;
    final Widget content = isLoading
        ? SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: spinnerColor,
            ),
          )
        : icon == null
            ? Text(label)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  Text(label),
                ],
              );

    final Widget button = switch (variant) {
      AppButtonVariant.primary => ElevatedButton(
          onPressed: isLoading ? null : onPressed,
          child: content,
        ),
      AppButtonVariant.secondary => OutlinedButton(
          onPressed: isLoading ? null : onPressed,
          child: content,
        ),
      AppButtonVariant.danger => ElevatedButton(
          onPressed: isLoading ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.danger,
            foregroundColor: AppColors.onPrimary,
          ),
          child: content,
        ),
      AppButtonVariant.text => TextButton(
          onPressed: isLoading ? null : onPressed,
          child: content,
        ),
    };

    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}
