import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/ride/ride_state_notifier.dart';
import '../../../core/location/location_service.dart';
import '../providers/availability_notifier.dart';
import '../../rides/presentation/offer_sheet.dart';

/// Driver home (online/offline + live location loop, plan 02).
/// Availability switch mirrors server profile; location stream pushes
/// when online and throttled to ≥5 s.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _offerShown = false;
  @override
  void initState() {
    super.initState();
    // Sync availability with server profile on first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profile = ref.read(driverProfileProvider);
      final avail = ref.read(availabilityProvider.notifier);
      avail.syncFromProfile(profile);
      // Start location stream if profile is online (crash recovery).
      final service = ref.read(locationServiceProvider);
      final permission = ref.read(appPermissionProvider);
      if (profile?.isOnline == true && permission.granted) {
        service.start();
      } else {
        service.start();
        service.requestPermission();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final driver = ref.watch(driverProfileProvider);
    final name = driver?.fullName.isNotEmpty == true
        ? driver!.fullName
        : 'Driver';
    final availability = ref.watch(availabilityProvider);
    final rideState = ref.watch(rideStateProvider);
    final offerId = rideState.offeredRideId;
    final permission = ref.watch(appPermissionProvider);

    if (offerId != null && driver?.isOnline == true && !_offerShown) {
      _offerShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (context) => const OfferSheet(),
        ).then((_) {
          if (mounted) setState(() => _offerShown = false);
        });
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const CircleAvatar(
              child: Icon(Icons.person),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name),
                  Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: driver?.isOnline == true
                              ? Colors.green
                              : Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        driver?.status ?? 'offline',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
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
      body: Column(
        children: [
          if (permission.deniedPermanently)
            Material(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.location_disabled, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Location access denied. Turn it on in settings to receive ride offers.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Switch(
                      value: availability.online,
                      onChanged: availability.inFlight
                          ? null
                          : (value) {
                              ref
                                  .read(availabilityProvider.notifier)
                                  .toggle();
                            },
                    ),
                    const SizedBox(height: 16),
                    Text(
                      availability.online ? 'Online' : 'Offline',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 8),
                    if (availability.online && offerId == null)
                      const Text(
                        "You're online — offers will appear here",
                        textAlign: TextAlign.center,
                      )
                    else if (!availability.online)
                      const Text(
                        'Go online to start receiving ride offers.',
                        textAlign: TextAlign.center,
                      ),
                    const SizedBox(height: 24),
                    // Live location tile for dev verification.
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.gps_fixed, size: 18),
                              SizedBox(width: 4),
                              Text('Live location'),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Status: ${driver?.status ?? 'unknown'}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            'Profile online: ${availability.online}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (availability.error != null)
                            Text(
                              'Error: ${availability.error}',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
