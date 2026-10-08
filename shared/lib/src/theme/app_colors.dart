import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Semantic colour roles for the one shared visual identity.
///
/// Both apps already render a single `ThemeData` built from [appSeedColor], but
/// feature code reached for `Colors.*` and `Color(0x…)` literals directly, so
/// the same role ("secondary text", "error surface") was expressed with a
/// different grey or red on every screen. These constants name the roles; the
/// Material [ColorScheme] stays the mapping and the accent stays the seed.
///
/// The two route-polyline roles are deliberately exact aliases of `Colors.blue`
/// / `Colors.grey`: the rider's Home and active-trip widget tests assert those
/// identity values (`home_screen_test.dart` `line.color == Colors.blue`,
/// `active_ride_screen_test.dart` `line.color == Colors.grey`).
class AppColors {
  AppColors._();

  /// The single accent, aliased to [appSeedColor] so there is one source.
  static const Color primary = appSeedColor;

  /// Text/icon on [primary].
  static const Color onPrimary = Colors.white;

  static const Color success = Colors.green;
  static const Color warning = Color(0xFFF9A825);
  static const Color danger = Colors.red;
  static const Color info = Colors.blue;

  /// Secondary/muted text and icons.
  static const Color muted = Color(0xFF757575);

  /// A softer muted tone for decorative icons.
  static const Color mutedFaint = Color(0xFFBDBDBD);

  /// A stronger muted tone for emphasised secondary text.
  static const Color mutedStrong = Color(0xFF616161);

  /// Default card/sheet background.
  static const Color surface = Colors.white;

  /// A subtle filled surface (the old `Colors.grey[100]`).
  static const Color surfaceMuted = Color(0xFFF5F5F5);

  /// A lighter subtle surface (the old `Colors.grey[50]`).
  static const Color surfaceLow = Color(0xFFFAFAFA);

  /// Hairline borders/dividers.
  static const Color outline = Color(0xFFE0E0E0);

  // Tinted status/banner surfaces in use today.
  static const Color estimateBanner = Color(0xFFFFF8E1);
  static const Color errorBanner = Color(0xFFFFEBEE);
  static const Color warningTint = Color(0xFFFFF8E1);
  static const Color warningBorder = Color(0xFFFFD54F);
  static const Color dangerTint = Color(0xFFFFEBEE);
  static const Color infoTint = Color(0xFFE3F2FD);

  // Foregrounds for the tinted surfaces.
  static const Color warningForeground = Color(0xFFEF6C00);
  static const Color dangerForeground = Color(0xFFD32F2F);
  static const Color infoForeground = Color(0xFF1976D2);

  /// Route-polyline colour for a road-following (ready) route.
  static const Color routeReady = Colors.blue;

  /// Route-polyline colour for an API-flagged estimate.
  static const Color routeEstimate = Colors.grey;
}
