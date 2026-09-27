import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_nav_section.dart';

/// The small heading between sidebar groups.
///
/// Both apps' drawers list their items flat under the header today, so this is
/// new copy on screen in both — a deliberate content change, not a regression.
class AppSidebarSectionHeader extends StatelessWidget {
  const AppSidebarSectionHeader({super.key, required this.section, this.title});

  /// Which group this heads.
  final AppNavSection section;

  /// Overrides [AppNavSection.title]. Left null the section's own heading is
  /// used, so both apps group identically by default.
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        title ?? section.title,
        style: AppTextStyles.sidebarSectionHeading,
      ),
    );
  }
}
