import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';

/// Driver home (bootstrap stage). The availability toggle, live location
/// stream, and the offer banner land with the online-loop work described in
/// `driver_app_plans/03-online-status-loop.md`; this screen currently shows a
/// read-only status card and app navigation.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final driver = ref.watch(driverProfileProvider);
    final name = driver?.fullName.isNotEmpty == true
        ? driver!.fullName
        : 'Driver';

    return Scaffold(
      appBar: AppBar(title: const Text('Driver Home')),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(name),
              accountEmail: Text('Status: ${driver?.status ?? 'unknown'}'),
              currentAccountPicture: const CircleAvatar(
                child: Icon(Icons.person),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Profile'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/profile');
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                context.push('/settings');
              },
            ),
          ],
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                driver?.isOnline == true
                    ? Icons.wifi
                    : Icons.wifi_off,
                size: 64,
                color: driver?.isOnline == true ? Colors.green : Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(driver?.isOnline == true ? 'Online' : 'Offline',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(
                'The availability toggle and live location stream arrive with '
                'the online-loop feature (driver_app_plans/03). Your session is '
                'ready and authenticated.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}