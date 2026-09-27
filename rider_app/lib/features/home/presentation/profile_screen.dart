import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../navigation/rider_nav_items.dart';
import '../../profile/providers/profile_notifier.dart';

/// Live rider profile: `GET /rider/me` data, an edit form persisting via
/// `PUT /rider/me`, and the tiles into the gated payment/security placeholders
/// and settings.
///
/// Mirrors `driver_app/lib/features/profile/presentation/profile_screen.dart`.
/// Email and phone both live on the `users` row (the session's `AuthUser`); the
/// phone is editable here, the email is not — the backend exposes no endpoint
/// that changes it.
///
/// The header, the form and the menu card are the shared widgets, so this screen
/// is left owning exactly three things: the display-name fallback, the `'R'`
/// initials for a nameless profile, and the post-save phone re-read.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  /// Seed for the shared form's phone field.
  ///
  /// Held in state rather than read straight from [authProvider] on every build
  /// because of the post-save re-read below: the form re-seeds a field only when
  /// this value *changes*, so an unrelated rebuild never clobbers what the rider
  /// is typing.
  String? _phoneSeed;

  @override
  void initState() {
    super.initState();
    _phoneSeed = ref.read(authProvider).user?.phone;
  }

  Future<void> _save({
    required String firstName,
    required String lastName,
    String? phone,
  }) async {
    // The shared form has already validated and trimmed, and hands over a phone
    // that is `null` when the field is blank — the computation this method used
    // to do itself.
    final ok = await ref
        .read(profileNotifierProvider.notifier)
        .updateProfile(firstName: firstName, lastName: lastName, phone: phone);
    if (!mounted) return;
    if (ok) {
      // The save re-reads `GET /rider/me`, so pull the confirmed phone back
      // into the field (`PUT /rider/me` never echoes the `users` row).
      final fresh = ref.read(authProvider).user?.phone;
      if (fresh != null) setState(() => _phoneSeed = fresh);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile saved')),
      );
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(profileNotifierProvider);
    final profile = state.profile;
    final email = ref.watch(authProvider).user?.email;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                AppProfileHeader(
                  // The name the rider set, falling back to their email. Never an
                  // invented label: an account with neither shows just the avatar.
                  displayName: profile.fullName.isNotEmpty
                      ? profile.fullName
                      : (email ?? ''),
                  photoUrl: profile.photoUrl,
                  secondaryLine: email,
                  // Nothing else on this screen prints the status, so the chip is
                  // the only place `idle` appears.
                  statusChipLabel: profile.status,
                  // Keyed on the *profile's* name, not the display name: the
                  // display name falls back to the email, so deriving from it
                  // would silently render the email's initial for a nameless
                  // rider.
                  initials: profile.fullName.isEmpty ? 'R' : null,
                ),
                const SizedBox(height: 24),
                AppProfileForm(
                  firstName: profile.firstName,
                  lastName: profile.lastName,
                  phone: _phoneSeed,
                  isSaving: state.saving,
                  errorText: state.error,
                  onSave: _save,
                ),
                const SizedBox(height: 8),
                // Fed from the same list the sidebar reads, minus `profile`,
                // which is the page this card sits on.
                AppNavLinkCard(
                  items: buildRiderNavItems()
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
