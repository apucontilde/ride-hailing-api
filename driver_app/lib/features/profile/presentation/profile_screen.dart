import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../navigation/driver_nav_items.dart';
import '../providers/profile_notifier.dart';

/// Driver profile (US-D3): live `GET /driver/me` data, edit form persisting
/// via `PUT /driver/me`, and tiles into the gated vehicle/documents screen
/// (plan 06), ride history (plan 05) and settings.
///
/// The header, the form and the menu card are the shared widgets, so this screen
/// is left owning exactly three things: the `'Driver'` display-name fallback, the
/// `onboardingStatus` chip copy, and the rating label.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  Future<void> _save({
    required String firstName,
    required String lastName,
    String? phone,
  }) async {
    // The shared form has already validated and trimmed, and hands over a phone
    // that is `null` when the field is blank — the computation this method used
    // to do itself. `ProfileNotifier` still sends only the fields it is given, so
    // a first/last-only save stays a first/last-only `PUT`.
    final ok = await ref
        .read(profileNotifierProvider.notifier)
        .updateProfile(firstName: firstName, lastName: lastName, phone: phone);
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved')),
      );
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(profileNotifierProvider);
    final driver = profile.driver;
    final ratingLabel =
        ref.read(profileNotifierProvider.notifier).ratingSummaryLabel;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: driver == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                AppProfileHeader(
                  // The `'Driver'` fallback stays app-side so the shared widget
                  // never invents a label. Known bug #3 (onboarding never `PUT`s
                  // /driver/me) means an empty `fullName` is the *common* path
                  // for a fresh driver, not an edge case — and it is also why no
                  // `initials:` argument is needed: the shared rule derives `'D'`
                  // from `'Driver'` on its own.
                  displayName:
                      driver.fullName.isEmpty ? 'Driver' : driver.fullName,
                  photoUrl: driver.photoUrl,
                  statusColor: driver.isOnline ? Colors.green : Colors.grey,
                  statusLabel: driver.status,
                  statusChipLabel: driver.onboardingStatus.isEmpty
                      ? 'Onboarding pending'
                      : driver.onboardingStatus,
                  ratingLabel: ratingLabel,
                ),
                const SizedBox(height: 24),
                AppProfileForm(
                  firstName: driver.firstName,
                  lastName: driver.lastName,
                  // No phone seed, deliberately: this app's `initState` has only
                  // ever seeded first/last, and `_save()` sends
                  // `phone: text.isEmpty ? null : text`. Pre-filling from
                  // `authProvider` the way the rider does would silently start
                  // writing a phone value this app never wrote before.
                  isSaving: profile.saving,
                  errorText: profile.error,
                  onSave: _save,
                ),
                const SizedBox(height: 8),
                // Fed from the same list the sidebar reads, minus `profile`,
                // which is the page this card sits on. With
                // `vehicleFeatureEnabled` false the vehicle row is absent from
                // both surfaces, which is what makes driver known bug #12
                // ("reachable only from inside /profile") false rather than
                // merely re-worded.
                AppNavLinkCard(
                  items: buildDriverNavItems()
                      .where(
                        (item) => item.destination != AppNavDestination.profile,
                      )
                      .toList(),
                  onItemSelected: (item) => context.push(item.route),
                ),
              ],
            ),
    );
  }
}
