import 'package:flutter/material.dart';

/// The seed both apps' colour schemes are generated from. It was the only colour
/// literal in this package before the navigation widgets arrived.
const Color appSeedColor = Color(0xFF1A73E8);

/// Spacing tokens.
///
/// The package's only paddings used to be the literal `16` and `14` inside
/// [AppTheme.light]'s `inputDecorationTheme`, so "make both apps space this the
/// same way" had nowhere to be expressed. `14` is not a token: it is an
/// input-specific vertical padding with no second consumer.
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Corner-radius tokens. `md` is the `12` the input and button themes already
/// used as a bare literal.
class AppRadii {
  AppRadii._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

/// Type tokens.
class AppTextStyles {
  AppTextStyles._();

  /// Heading between sidebar groups (`ACCOUNT`, `ACTIVITY`, …). Deliberately a
  /// fixed colour rather than a `colorScheme` role so the two apps' headings
  /// cannot drift with their schemes.
  static const TextStyle sidebarSectionHeading = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: Color(0xFF5F6368),
  );
}

class AppTheme {
  static ThemeData get light {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: appSeedColor,
      brightness: Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 14,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
      ),
      // The three sub-themes below are the shared sidebar's visual vocabulary.
      // Each value is pinned to what Material 3 already resolves to, so naming
      // them changes nothing on the screens that were already rendering — the
      // point is that both apps now read the same numbers from one place instead
      // of both inheriting defaults separately. The single exception is
      // `selectedTileColor`, which only affects a `selected: true` row; no app
      // had one before the sidebar.
      drawerTheme: DrawerThemeData(
        width: 304,
        backgroundColor: colorScheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 1,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadiusDirectional.horizontal(
            end: Radius.circular(AppRadii.lg),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        selectedTileColor: colorScheme.primary.withValues(alpha: 0.08),
        selectedColor: colorScheme.primary,
        contentPadding: const EdgeInsetsDirectional.only(start: 16, end: 24),
        shape: const RoundedRectangleBorder(),
      ),
      dialogTheme: DialogThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
    );
  }
}
