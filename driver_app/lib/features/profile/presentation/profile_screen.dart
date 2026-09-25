import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/utils/validators.dart';
import '../../driver/model/driver_profile.dart';
import '../providers/profile_notifier.dart';

/// Driver profile (US-D3): live `GET /driver/me` data, edit form persisting
/// via `PUT /driver/me`, and tiles into the gated vehicle/documents screen
/// (plan 06), ride history (plan 05) and settings.
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
    final driver = ref.read(profileNotifierProvider).driver;
    _firstNameController.text = driver?.firstName ?? '';
    _lastNameController.text = driver?.lastName ?? '';
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
    final ok = await ref.read(profileNotifierProvider.notifier).updateProfile(
          firstName: _firstNameController.text.trim(),
          lastName: _lastNameController.text.trim(),
          phone: _phoneController.text.trim().isEmpty
              ? null
              : _phoneController.text.trim(),
        );
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
                _ProfileHeader(driver: driver, ratingLabel: ratingLabel),
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
                          if (profile.error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              profile.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ],
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            key: const Key('profile-save-button'),
                            onPressed: profile.saving ? null : _save,
                            icon: profile.saving
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
                        leading: const Icon(Icons.directions_car_outlined),
                        title: const Text('Vehicle & documents'),
                        subtitle: const Text('Verification'),
                        onTap: () => context.push('/vehicle'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.history),
                        title: const Text('Ride history'),
                        subtitle: const Text('Earnings & past trips'),
                        onTap: () => context.push('/rides-history'),
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
  const _ProfileHeader({required this.driver, required this.ratingLabel});

  final DriverProfile driver;
  final String ratingLabel;

  String get _initials {
    if (driver.firstName.isEmpty && driver.lastName.isEmpty) return 'D';
    final parts = <String>[
      if (driver.firstName.isNotEmpty) driver.firstName,
      if (driver.lastName.isNotEmpty) driver.lastName,
    ];
    return parts.map((part) => part[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPhoto = driver.photoUrl != null && driver.photoUrl!.isNotEmpty;
    return Column(
      children: [
        CircleAvatar(
          radius: 40,
          backgroundColor: Colors.blue.shade100,
          backgroundImage:
              hasPhoto ? NetworkImage(driver.photoUrl!) : null,
          child: hasPhoto
              ? null
              : Text(_initials, style: theme.textTheme.headlineMedium),
        ),
        const SizedBox(height: 12),
        Text(
          driver.fullName.isEmpty ? 'Driver' : driver.fullName,
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: driver.isOnline ? Colors.green : Colors.grey,
              ),
            ),
            const SizedBox(width: 6),
            Text(driver.status),
          ],
        ),
        const SizedBox(height: 8),
        Chip(
          label: Text(
            driver.onboardingStatus.isEmpty
                ? 'Onboarding pending'
                : driver.onboardingStatus,
          ),
          visualDensity: VisualDensity.compact,
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.star, size: 18, color: Colors.amber),
            const SizedBox(width: 4),
            Text(ratingLabel),
          ],
        ),
      ],
    );
  }
}
