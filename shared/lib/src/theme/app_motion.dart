import 'package:flutter/animation.dart';

/// Motion tokens for animated states (sheet snapping, panel resize, banners).
///
/// Named once so the two apps and the shared components cannot pick different
/// durations/curves for the same interaction.
class AppMotion {
  AppMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  /// The standard curve for in-place state changes.
  static const Curve standard = Curves.easeInOut;

  /// A stronger curve for entrances/exits and snapping.
  static const Curve emphasized = Curves.easeOutCubic;
}
