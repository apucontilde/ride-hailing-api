import 'package:flutter/material.dart';

/// The account data the sidebar header renders — a plain value object, never an
/// [Element], so tests scope header finders to the header *widget*.
///
/// Every field is optional with a default so `const AppSidebarAccount()`
/// compiles: the rider supplies a name and an email, the driver supplies a name,
/// a status and a rating, and neither supplies the other's.
///
/// [secondaryLine] and [statusLabel] are an **either/or** pair. The rider's
/// second line is the account email; the driver's is a status, which today is
/// smuggled into `UserAccountsDrawerHeader`'s `accountEmail` slot as the literal
/// `'Status: online'`. Passing both would render the status twice, so
/// [statusLabel] wins — see `AppSidebarHeader`.
class AppSidebarAccount {
  const AppSidebarAccount({
    this.displayName = '',
    this.photoUrl,
    this.initials,
    this.secondaryLine,
    this.statusLabel,
    this.statusColor,
    this.ratingLabel,
  });

  /// The name to show. Empty renders the avatar with no name row rather than an
  /// empty `Text`.
  final String displayName;

  /// Avatar photo. Null **and** empty/blank both mean "no photo" — the two app
  /// models disagree (`RiderProfile` normalises `'' → null`, `DriverProfile`
  /// passes JSON straight through), so the widgets normalise instead of making
  /// every caller pre-check.
  final String? photoUrl;

  /// Explicit initials for the no-photo case. Left null, the header derives up
  /// to two letters from [displayName] itself.
  final String? initials;

  /// Plain line under the name (the rider's email). Ignored when [statusLabel]
  /// is non-empty.
  final String? secondaryLine;

  /// Status text on the dot row (the driver's `online`/`offline`).
  final String? statusLabel;

  /// Dot colour for the status row.
  final Color? statusColor;

  /// Star-rating line (driver only).
  final String? ratingLabel;
}
