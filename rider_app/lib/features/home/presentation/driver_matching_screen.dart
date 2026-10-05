import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../data/ride_status_provider.dart';
import '../data/current_ride_provider.dart';
import '../data/home_provider.dart';
import '../data/location_ping_service.dart';

class DriverMatchingScreen extends ConsumerStatefulWidget {
  final VoidCallback? onCancelled;

  const DriverMatchingScreen({super.key, this.onCancelled});

  @override
  ConsumerState<DriverMatchingScreen> createState() => _DriverMatchingScreenState();
}

class _DriverMatchingScreenState extends ConsumerState<DriverMatchingScreen>
    with WidgetsBindingObserver {
  bool _navigating = false;
  bool _cancelInFlight = false;
  late final CurrentRideNotifier _currentRideNotifier;
  LocationPingService? _pingService;

  @override
  void initState() {
    super.initState();
    // `HomeScreen` is disposed by the `context.go('/driver-matching')` that got
    // us here; hold the ping lease for the matching wait too, so a driver can be
    // matched against a fresh rider position.
    WidgetsBinding.instance.addObserver(this);
    _pingService = ref.read(locationPingServiceProvider);
    _pingService!.start();
    _currentRideNotifier = ref.read(currentRideProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _currentRideNotifier.startPolling();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _pingService?.start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pingService?.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingService?.stop();
    _currentRideNotifier.stopPolling();
    super.dispose();
  }

  void _goHome() {
    if (_navigating) return;
    _navigating = true;
    _currentRideNotifier.stopPolling();
    context.go('/home');
  }

  Future<void> _cancelRequest() async {
    final onCancelled = widget.onCancelled;
    if (onCancelled != null) {
      onCancelled();
      return;
    }
    if (_cancelInFlight) return;

    final rideId =
        ref.read(rideStatusProvider).rideId ?? ref.read(rideCreationProvider).rideId;
    if (rideId == null) {
      _goHome();
      return;
    }

    _cancelInFlight = true;
    await ref.read(rideCreationProvider.notifier).cancelRide(rideId);
    _cancelInFlight = false;
    if (!mounted) return;

    final creationState = ref.read(rideCreationProvider);
    if (creationState.cancelError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(creationState.cancelError!)),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ride cancelled successfully')),
    );
    _goHome();
  }

  @override
  Widget build(BuildContext context) {
    final rideState = ref.watch(rideStatusProvider);
    final pollState = ref.watch(currentRideProvider);
    final showNoDrivers = rideState.status == RideStatus.noDriverAvailable ||
        pollState.noDriverAvailable;

    ref.listen<RideState>(rideStatusProvider, (previous, next) {
      if (_navigating) return;
      switch (next.status) {
        case RideStatus.driverApproaching:
          _navigating = true;
          _currentRideNotifier.stopPolling();
          context.go('/active-ride');
        case RideStatus.cancelled:
          _goHome();
        case RideStatus.noDriverAvailable:
          _currentRideNotifier.stopPolling();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No drivers found right now. Please try again.')),
          );
        default:
          break;
      }
    });

    if (rideState.status == RideStatus.driverApproaching && !_navigating) {
      // Navigate to active ride screen
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_navigating && mounted) {
          _navigating = true;
          _currentRideNotifier.stopPolling();
          context.go('/active-ride');
        }
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Finding Driver'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: showNoDrivers ? _goHome : _cancelRequest,
        ),
      ),
      body: Center(
        child: showNoDrivers
            ? _buildNoDriversView()
            : _buildSearchingView(pollState),
      ),
    );
  }

  Widget _buildSearchingView(CurrentRideState pollState) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 80,
          height: 80,
          child: CircularProgressIndicator(strokeWidth: 4),
        ),
        const SizedBox(height: 24),
        Text(
          'Finding your driver...',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          pollState.stillSearching
              ? 'No driver nearby yet, still searching'
              : 'Searching for nearby drivers',
          style: TextStyle(color: Colors.grey[600]),
        ),
        const SizedBox(height: 24),
        TextButton(
          onPressed: _cancelInFlight ? null : _cancelRequest,
          child: const Text('Cancel request'),
        ),
      ],
    );
  }

  Widget _buildNoDriversView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.no_accounts_outlined, size: 80, color: Colors.grey[500]),
        const SizedBox(height: 24),
        Text(
          'No drivers found',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          'No nearby drivers are available right now. Please try again later.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey[600]),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _goHome,
          child: const Text('Back to Home'),
        ),
      ],
    );
  }
}