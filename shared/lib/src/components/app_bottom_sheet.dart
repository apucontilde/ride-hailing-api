import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// The shared bottom-sheet surface: white, rounded at the top, lifted by a
/// shadow. The handle is a separate [AppSheetHandle] so a sheet whose handle
/// scrolls with its content (Home's booking sheet) can place it inside the
/// scroll view.
class AppBottomSheet extends StatelessWidget {
  const AppBottomSheet({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.elevation,
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;

  /// Top-radius override. Defaults to [AppRadii.sheet].
  final BorderRadius? borderRadius;

  /// Shadow blur radius. Defaults to the `10` the sheets used.
  final double? elevation;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? AppColors.surface,
        borderRadius: borderRadius ??
            const BorderRadius.vertical(
              top: Radius.circular(AppRadii.sheet),
            ),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: elevation ?? 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// The drag handle capsule a sheet renders at its top.
class AppSheetHandle extends StatelessWidget {
  const AppSheetHandle({
    super.key,
    this.width = 40,
    this.height = 4,
    this.margin,
  });

  final double width;
  final double height;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: width,
        height: height,
        margin: margin,
        decoration: BoxDecoration(
          color: AppColors.outline,
          borderRadius: BorderRadius.circular(AppRadii.handle),
        ),
      ),
    );
  }
}
