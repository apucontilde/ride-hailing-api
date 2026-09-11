import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_provider.dart';

/// Driver profile from `GET /driver/me` (US-D3). Editing and the
/// feature-gated vehicle/documents surfaces land in `driver_app_plans/04`.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(driverProfileProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: driver == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: Colors.blue.shade100,
                  child: driver.photoUrl != null && driver.photoUrl!.isNotEmpty
                      ? null
                      : const Icon(Icons.person, size: 40),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Text(
                    driver.fullName.isEmpty ? 'Driver' : driver.fullName,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 8),
                Center(child: Text('Status: ${driver.status}')),
                const SizedBox(height: 24),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.star_outline),
                    title: const Text('Rating'),
                    subtitle: Text(
                      driver.ratingSummary.isEmpty
                          ? 'New driver'
                          : driver.ratingSummary,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('Onboarding'),
                    subtitle: Text(driver.onboardingStatus),
                    onTap: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Vehicle & documents onboarding ships with a later plan '
                            '(feature-gated until the backend is real).',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}