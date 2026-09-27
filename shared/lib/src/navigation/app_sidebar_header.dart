import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_sidebar_account.dart';

/// Collapses the two shapes an avatar photo arrives in to one.
///
/// `null`, `''` and whitespace all mean "no photo". This cannot be pushed onto
/// callers: `RiderProfile` normalises `'' → null` in `fromJson`, but
/// `DriverProfile` passes `json['photo_url']` straight through and hands back
/// `''` for every driver without a photo — the common case. A naive
/// `photoUrl != null ? NetworkImage(photoUrl!) : null` therefore calls
/// `NetworkImage('')`, which paints a red error box inside the avatar and throws
/// an unhandled async image error under `flutter_test`.
String? normalisePhotoUrl(String? photoUrl) {
  final trimmed = (photoUrl ?? '').trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Up to two initials: the first letter of the first two words of [displayName],
/// uppercased.
///
/// This is the rule both apps' hand-rolled headers already implement, and the
/// rider's `profile_screen_test.dart` asserts its output (`'Ana Rojas'` → `'AR'`),
/// so it lives here once rather than twice.
String deriveInitials(String displayName) {
  return displayName
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) => part[0].toUpperCase())
      .take(2)
      .join();
}

/// The sidebar's account block — the replacement for
/// `UserAccountsDrawerHeader`.
///
/// Two things it fixes that the widget it replaces cannot: the whole header is
/// tappable (`UserAccountsDrawerHeader` only exposes `onDetailsPressed` on the
/// name/email, so the rider had to wrap it in a `GestureDetector` and the driver
/// simply had an inert header), and the avatar honours `photoUrl` instead of a
/// hardcoded person glyph.
class AppSidebarHeader extends StatelessWidget {
  const AppSidebarHeader({super.key, required this.account, this.onTap});

  /// Name, photo, and the either/or second line.
  final AppSidebarAccount account;

  /// Invoked when anywhere in the header is tapped. The app pops the sidebar and
  /// pushes its own route — this package has no router.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = normalisePhotoUrl(account.photoUrl);
    final initials = account.initials ?? deriveInitials(account.displayName);
    final name = account.displayName;

    final status = account.statusLabel?.trim() ?? '';
    final showStatus = status.isNotEmpty;
    final secondary = account.secondaryLine?.trim() ?? '';
    // `statusLabel` beats `secondaryLine`, and the secondary line is hidden when
    // it *is* the display name, so neither line is ever printed twice.
    final showSecondary =
        !showStatus && secondary.isNotEmpty && secondary != name;
    final rating = account.ratingLabel?.trim() ?? '';

    return SafeArea(
      bottom: false,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: Colors.blue.shade100,
                backgroundImage: photo == null ? null : NetworkImage(photo),
                child: photo != null || initials.isEmpty
                    ? null
                    : Text(initials, style: theme.textTheme.titleMedium),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (name.isNotEmpty)
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    if (showStatus)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Row(
                          children: [
                            Container(
                              key: const Key('status-dot'),
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: account.statusColor ?? Colors.grey,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (showSecondary)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          secondary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                    if (rating.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: Text(
                          rating,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
