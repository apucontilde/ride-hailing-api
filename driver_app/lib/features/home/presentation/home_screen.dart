import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/app_bootstrap.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/ride/ride_state_notifier.dart';
import '../../../core/location/location_service.dart';
import '../providers/availability_notifier.dart';
import '../../rides/data/rides_repository.dart';
import '../../rides/presentation/offer_sheet.dart';

/// Driver home (online/offline + live location loop, plan 02).
/// Availability switch mirrors server profile; location stream pushes
/// when online and throttled to ≥5 s.
///
/// Also the entry point to the trip journey (plan 04): once a ride is held the
/// driver is pushed onto `/trip`, and a ride that is still active when the app
/// launches is restored from `GET /driver/rides/current` (the websocket has no
/// replay, so without this a driver mid-trip would land on an empty home).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// Id of the offer whose sheet has already been presented.
  ///
  /// Keyed to the ride id rather than a bare bool so the latch releases itself
  /// when the offer is withdrawn (declined, timed out, or replaced): a driver
  /// who missed the first offer would otherwise be permanently shielded from
  /// the second one by a flag for a sheet that is not on screen.
  String? _offerLatch;
  bool _tripPushed = false;
  bool _restoreTried = false;

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
      service.start();
      if (!permission.granted && !permission.deniedPermanently) {
        service.requestPermission();
      }
      _restoreActiveTrip();
    });
  }

  /// Adopts the server's active ride (if any) so the trip screen can be
  /// entered straight away after a cold start or a crash.
  ///
  /// The session bootstrap (`core/app_bootstrap.dart`) owns this restore on
  /// every entry path now; this stays as the fallback for a Home mount that did
  /// not run the bootstrap (e.g. a standalone widget test), and skips when the
  /// bootstrap already attempted it so the endpoint is never polled twice.
  Future<void> _restoreActiveTrip() async {
    if (_restoreTried) return;
    _restoreTried = true;
    if (ref.read(sessionBootstrapProvider).restoreAttempted) return;
    try {
      final ride = await ref.read(ridesRepositoryProvider).currentRide();
      if (ride == null || !mounted) return;
      ref.read(rideStateProvider.notifier).adoptRide(ride);
    } catch (_) {
      // Non-fatal: an offline or rejected restore just means no active trip.
    }
  }

  @override
  Widget build(BuildContext context) {
    final driver = ref.watch(driverProfileProvider);
    final name = driver?.fullName.isNotEmpty == true
        ? driver!.fullName
        : 'Driver';
    // The sidebar header shows the same rating the profile screen does; that
    // read now lives in `DriverShell`, which owns the single `AppSidebar`.
    final availability = ref.watch(availabilityProvider);
    final rideState = ref.watch(rideStateProvider);
    final offerId = rideState.offeredRideId;
    final heldRide = rideState.currentRide;
    final permission = ref.watch(appPermissionProvider);

    // Gated on the offer alone — deliberately *not* on
    // `driverProfileProvider`'s `isOnline`.
    //
    // Dispatch only ever offers to a driver the server already considers
    // online, located and websocket-connected, so re-deriving that here from a
    // cached profile could only ever discard a legitimate offer. It did
    // exactly that: the status toggle left the cache at its login-time value
    // (see AvailabilityNotifier.toggle), so every offer the websocket
    // delivered was dropped and then expired after 30 s. Reading the offer
    // itself makes the sheet immune to cache staleness.
    if (offerId != null && offerId != _offerLatch) {
      _offerLatch = offerId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          // A live offer must only end on an explicit Accept/Pass (or the
          // in-sheet Dismiss on expiry) — never a scrim tap or a drag-down.
          isDismissible: false,
          enableDrag: false,
          builder: (context) => const OfferSheet(),
        );
      });
    } else if (offerId == null) {
      // Withdrawn or expired: let the next offer through.
      _offerLatch = null;
    }

    if (heldRide == null) {
      _tripPushed = false;
    } else if (!_tripPushed) {
      _tripPushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.push('/trip');
      });
    }

    return Column(
      children: [
        // Home's rich header (avatar + name + status dot) used to be the AppBar
        // title. It now lives at the top of this body because `DriverShell` owns
        // the only AppBar/drawer; it must NOT grow a second Scaffold.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              const CircleAvatar(child: Icon(Icons.person)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name),
                    AppBadge(
                      label: driver?.status ?? 'offline',
                      color: driver?.isOnline == true
                          ? AppColors.success
                          : AppColors.muted,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (permission.deniedPermanently)
          Material(
            color: AppColors.dangerTint,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.location_disabled, color: AppColors.danger),
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
        if (heldRide != null)
          Material(
            color: AppColors.infoTint,
            child: InkWell(
              key: const Key('home-active-trip'),
              onTap: () {
                _tripPushed = true;
                context.push('/trip');
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.local_taxi, color: AppColors.info),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Active trip (${heldRide.status})',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            'Tap to return to the trip',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
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
                            ref.read(availabilityProvider.notifier).toggle();
                            // Going online must publish a position straight
                            // away. Fixes that arrived while offline were
                            // dropped, and geolocator does not re-emit while
                            // the driver is stationary, so without this the
                            // driver has no `driver_positions` row at all and
                            // dispatch can never find them — online, waiting,
                            // never offered a ride, nothing on screen to
                            // explain why.
                            if (value) {
                              ref
                                  .read(locationServiceProvider)
                                  .publishLastPosition();
                            }
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
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
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
                            style: AppTextStyles.caption.copyWith(
                              color: AppColors.danger,
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
    );
  }
}
