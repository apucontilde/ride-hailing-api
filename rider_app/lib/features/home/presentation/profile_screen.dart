import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/utils/validators.dart';
import '../../profile/providers/profile_notifier.dart';
import '../model/rider_profile.dart';

/// Live rider profile: `GET /rider/me` data, an edit form persisting via
/// `PUT /rider/me`, and the tiles into the gated payment/security placeholders
/// and settings.
///
/// Mirrors `driver_app/lib/features/profile/presentation/profile_screen.dart`.
/// Email and phone both live on the `users` row (the session's `AuthUser`); the
/// phone is editable here, the email is not — the backend exposes no endpoint
/// that changes it.
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _firstNameController;
  late final TextEditingController _lastNameController;
  late final TextEditingController _phoneController;

  @override
  void initState() {
    super.initState();
    _firstNameController = TextEditingController();
    _lastNameController = TextEditingController();
    _phoneController = TextEditingController();
    final profile = ref.read(profileNotifierProvider).profile;
    _firstNameController.text = profile?.firstName ?? '';
    _lastNameController.text = profile?.lastName ?? '';
    _phoneController.text = ref.read(authProvider).user?.phone ?? '';
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final phone = _phoneController.text.trim();
    final ok = await ref.read(profileNotifierProvider.notifier).updateProfile(
          firstName: _firstNameController.text.trim(),
          lastName: _lastNameController.text.trim(),
          phone: phone.isEmpty ? null : phone,
        );
    if (!mounted) return;
    if (ok) {
      // The save re-reads `GET /rider/me`, so pull the confirmed phone back
      // into the field (`PUT /rider/me` never echoes the `users` row).
      final fresh = ref.read(authProvider).user?.phone;
      if (fresh != null) _phoneController.text = fresh;
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
    final user = ref.watch(authProvider).user;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: profile == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                _ProfileHeader(profile: profile, email: user?.email),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'Edit profile',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            controller: _firstNameController,
                            decoration: const InputDecoration(
                              labelText: 'First name',
                              border: OutlineInputBorder(),
                            ),
                            validator: Validators.validateName,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _lastNameController,
                            decoration: const InputDecoration(
                              labelText: 'Last name',
                              border: OutlineInputBorder(),
                            ),
                            validator: Validators.validateName,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _phoneController,
                            keyboardType: TextInputType.phone,
                            decoration: const InputDecoration(
                              labelText: 'Phone',
                              hintText: 'Optional',
                              border: OutlineInputBorder(),
                            ),
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return null;
                              }
                              return Validators.validatePhone(value);
                            },
                          ),
                          if (state.error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              state.error!,
                              key: const Key('profile-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            key: const Key('profile-save-button'),
                            onPressed: state.saving ? null : _save,
                            icon: state.saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child:
                                        CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: const Text('Save'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: const Text('Ride history'),
                        subtitle: const Text('Past trips'),
                        onTap: () => context.push('/history'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.credit_card),
                        title: const Text('Payment'),
                        subtitle: const Text('Cards & receipts'),
                        onTap: () => context.push('/payment'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.shield_outlined),
                        title: const Text('Security'),
                        subtitle: const Text('Emergency contacts'),
                        onTap: () => context.push('/security'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.settings_outlined),
                        title: const Text('Settings'),
                        subtitle: const Text('Account & sign out'),
                        onTap: () => context.push('/settings'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader({required this.profile, required this.email});

  final RiderProfile profile;
  final String? email;

  String get _initials {
    final name = profile.fullName;
    if (name.isEmpty) return 'R';
    return name
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase())
        .take(2)
        .join();
  }

  /// The name the rider set, falling back to their email. Never an invented
  /// label: an account with neither shows just the avatar and status.
  String get _displayName {
    if (profile.fullName.isNotEmpty) return profile.fullName;
    return email?.isNotEmpty == true ? email! : '';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _displayName;
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Colors.blue.shade100,
          backgroundImage:
              profile.hasPhoto ? NetworkImage(profile.photoUrl!) : null,
          child: profile.hasPhoto
              ? null
              : Text(_initials, style: theme.textTheme.headlineMedium),
        ),
        const SizedBox(height: 12),
        if (name.isNotEmpty) ...[
          Text(
            name,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          // Hidden when it *is* the display name, so it is never printed twice.
          if (profile.fullName.isNotEmpty && email != null && email!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(email!, style: TextStyle(color: Colors.grey[600])),
            ),
        ],
        const SizedBox(height: 8),
        Chip(
          label: Text(profile.status),
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }
}
