import 'package:flutter/material.dart';

import '../navigation/app_sidebar_header.dart'
    show deriveInitials, normalisePhotoUrl;
import '../theme/app_theme.dart';

/// The profile screen's avatar-and-name block.
///
/// Replaces two hand-rolled `_ProfileHeader` widgets that had already drifted:
/// the rider's shows an email and a status `Chip`, the driver's shows an online
/// dot, an `onboardingStatus` `Chip` and a star rating. Every one of those is an
/// optional parameter here, so the two keep their own behaviour while the
/// avatar/name block is identical — the apps pass data, this widget never
/// branches on which app it is in.
///
/// Four behaviours live here rather than in the apps, because existing tests
/// assert them and they were previously duplicated:
///
/// * initials are the first letters of up to two words, uppercased
///   (`'Ana Rojas'` → `'AR'`, asserted by the rider's profile suite);
/// * [secondaryLine] is hidden when it is empty **or equal to** [displayName], so
///   an email used as the display-name fallback is never printed twice;
/// * the [statusChipLabel] chip renders whenever it is non-null;
/// * an empty [displayName] renders the avatar alone, with no empty `Text`.
class AppProfileHeader extends StatelessWidget {
  const AppProfileHeader({
    super.key,
    required this.displayName,
    this.photoUrl,
    this.secondaryLine,
    this.statusColor,
    this.statusLabel,
    this.statusChipLabel,
    this.ratingLabel,
    this.initials,
  });

  /// The name to show. The app owns any fallback (`'Driver'`, or the email) —
  /// this widget never invents a label.
  final String displayName;

  /// Avatar photo. Null and empty/blank both mean "no photo"; see
  /// [normalisePhotoUrl] for why the widget normalises instead of the caller.
  final String? photoUrl;

  /// Line under the name (the rider's email).
  final String? secondaryLine;

  /// Online-dot colour (the driver).
  final Color? statusColor;

  /// Dot-row text (the driver's `online`/`offline`).
  final String? statusLabel;

  /// Chip text — the rider's profile `status`, the driver's `onboardingStatus`.
  final String? statusChipLabel;

  /// Star-rating line (the driver).
  final String? ratingLabel;

  /// Explicit initials, for the empty-name case only.
  ///
  /// The rider passes `'R'` when its *profile* has no name, because its
  /// [displayName] falls back to the email and deriving from that would silently
  /// render the email's initial instead. The driver passes nothing: its
  /// `'Driver'` fallback already derives to `'D'`.
  final String? initials;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final photo = normalisePhotoUrl(photoUrl);
    final effectiveInitials = initials ?? deriveInitials(displayName);
    final secondary = secondaryLine?.trim() ?? '';
    final showSecondary = secondary.isNotEmpty && secondary != displayName;
    final status = statusLabel?.trim() ?? '';
    final rating = ratingLabel?.trim() ?? '';

    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Colors.blue.shade100,
          backgroundImage: photo == null ? null : NetworkImage(photo),
          child: photo != null || effectiveInitials.isEmpty
              ? null
              : Text(effectiveInitials, style: theme.textTheme.headlineMedium),
        ),
        const SizedBox(height: AppSpacing.md),
        if (displayName.isNotEmpty) ...[
          Text(
            displayName,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          if (showSecondary)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                secondary,
                style: TextStyle(color: Colors.grey[600]),
              ),
            ),
        ],
        if (status.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                // Keyed because the avatar paints a circular `Container` of its
                // own, so shape alone cannot single the dot out in a test.
                key: const Key('status-dot'),
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor ?? Colors.grey,
                ),
              ),
              const SizedBox(width: 6),
              Text(status),
            ],
          ),
        ],
        if (statusChipLabel != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Chip(
            label: Text(statusChipLabel!),
            visualDensity: VisualDensity.compact,
          ),
        ],
        if (rating.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.star, size: 18, color: Colors.amber),
              const SizedBox(width: AppSpacing.xs),
              Text(rating),
            ],
          ),
        ],
      ],
    );
  }
}
