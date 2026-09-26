import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:latlong2/latlong.dart';
import '../../../core/location/location_service.dart';
import '../../../core/ride/ride_state_notifier.dart';
import '../providers/trip_notifier.dart';

/// Tile layer for the trip map, behind a provider so widget tests can
/// override it with `null` and never touch the network (`flutter_test`'s HTTP
/// override rejects tile requests, which would fail the frame).
final tripMapTileProvider = Provider<TileLayer?>((ref) {
  return TileLayer(
    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    userAgentPackageName: 'com.driver.app',
  );
});

/// Trip journey screen (US-D7/D8/D9, US-11): one stage-driven primary button
/// over a flutter_map route, driver-initiated cancel, and a clean landing
/// screen for a completed or cancelled trip.
///
/// Route origin is the driver's own live GPS fix ([lastPositionProvider]); the
/// target is the pickup until the trip starts, then the dropoff. A route that
/// the backend cannot road-follow (500, or an `is_estimate` straight line) is
/// drawn as a dashed overlay instead.
class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key});

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  final MapController _mapController = MapController();
  String? _fittedKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncRoute());
  }

  /// Requests the road route to the current target. Safe to call on every
  /// position update: the notifier's 200 m cache collapses repeats, and
  /// `fetchRoute` itself dedupes concurrent calls.
  void _syncRoute() {
    final trip = ref.read(tripNotifierProvider);
    final position = ref.read(lastPositionProvider);
    final ride = trip.currentRide;
    if (ride == null || position == null) return;
    final target = _targetFor(trip.stage, ride);
    if (target == null) return;
    ref.read(tripNotifierProvider.notifier).fetchRoute(
          fromLat: position.lat,
          fromLng: position.lng,
          toLat: target.lat,
          toLng: target.lng,
          currentLat: position.lat,
          currentLng: position.lng,
        );
  }

  /// Where the driver is heading at this stage, or `null` when the trip is
  /// over and no route is needed.
  static ({double lat, double lng, String address})? _targetFor(
    TripStage stage,
    Ride ride,
  ) {
    switch (stage) {
      case TripStage.driving:
        final lat = ride.dropoffLat;
        final lng = ride.dropoffLng;
        if (lat == null || lng == null) return null;
        return (lat: lat, lng: lng, address: ride.dropoffAddress ?? 'Dropoff');
      case TripStage.pre:
      case TripStage.enrouteToPickup:
      case TripStage.arrived:
        final lat = ride.pickupLat;
        final lng = ride.pickupLng;
        if (lat == null || lng == null) return null;
        return (lat: lat, lng: lng, address: ride.pickupAddress ?? 'Pickup');
      case TripStage.post:
      case TripStage.cancelled:
        return null;
    }
  }

  void _fitTo(List<LatLng> points, String key) {
    if (points.length < 2 || _fittedKey == key) return;
    _fittedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: points,
          padding: const EdgeInsets.all(48),
          maxZoom: 16,
        ),
      );
    });
  }

  /// Ends the trip locally: drop the held ride (so `/home` no longer routes
  /// back here) and the cached route, then land on home.
  void _finishTrip() {
    ref.read(rideStateProvider.notifier).clearRide();
    ref.read(tripNotifierProvider.notifier).reset();
    if (mounted) context.go('/home');
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('trip-cancel-dialog'),
        title: const Text('Cancel this trip?'),
        content: const Text(
          'The rider is notified and the trip goes back to dispatch. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep driving'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Cancel trip'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(tripNotifierProvider.notifier).cancelTrip();
  }

  Future<void> _confirmComplete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('trip-complete-dialog'),
        title: const Text('Complete trip?'),
        content: const Text('Completing ends the trip and pays out the fare.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(tripNotifierProvider.notifier).advance();
  }

  @override
  Widget build(BuildContext context) {
    final trip = ref.watch(tripNotifierProvider);
    final position = ref.watch(lastPositionProvider);
    final ride = trip.currentRide;
    final stage = trip.stage;

    // Refetch on GPS moves (collapsed by the 200 m cache) and when the target
    // flips from pickup to dropoff as the trip starts.
    ref.listen<GeoPoint?>(lastPositionProvider, (previous, next) {
      if (previous != next) _syncRoute();
    });
    ref.listen<TripState>(tripNotifierProvider, (previous, next) {
      if (previous?.stage != next.stage) _syncRoute();
    });

    return PopScope(
      // A finished trip must not be left half-cleared by a back gesture.
      canPop: !trip.isTerminal,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _finishTrip();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Trip'),
          automaticallyImplyLeading: !trip.isTerminal,
        ),
        body: Column(
          children: [
            Expanded(
              flex: 3,
              child: ride == null
                  ? const Center(child: Text('No active trip'))
                  : _MapView(
                      controller: _mapController,
                      stage: stage,
                      pickup: (lat: ride.pickupLat, lng: ride.pickupLng),
                      dropoff: (lat: ride.dropoffLat, lng: ride.dropoffLng),
                      driverPosition: position,
                      route: trip.route,
                      onFit: _fitTo,
                    ),
            ),
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _StageControls(
                  stage: stage,
                  ride: ride,
                  route: trip.route,
                  cancelledBy: trip.cancelledBy,
                  canCancel: trip.canCancel,
                  onAdvance: () =>
                      ref.read(tripNotifierProvider.notifier).advance(),
                  onCancel: _confirmCancel,
                  onComplete: _confirmComplete,
                  onFinish: _finishTrip,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapView extends ConsumerWidget {
  final MapController controller;
  final TripStage stage;
  final ({double? lat, double? lng}) pickup;
  final ({double? lat, double? lng}) dropoff;
  final GeoPoint? driverPosition;
  final RouteCache? route;
  final void Function(List<LatLng> points, String key) onFit;

  const _MapView({
    required this.controller,
    required this.stage,
    required this.pickup,
    required this.dropoff,
    required this.driverPosition,
    required this.route,
    required this.onFit,
  });

  bool get _hasPickup => pickup.lat != null && pickup.lng != null;
  bool get _hasDropoff => dropoff.lat != null && dropoff.lng != null;

  LatLng? get _pickupPoint =>
      _hasPickup ? LatLng(pickup.lat!, pickup.lng!) : null;
  LatLng? get _dropoffPoint =>
      _hasDropoff ? LatLng(dropoff.lat!, dropoff.lng!) : null;

  /// The road-following points, or an empty list when there is no usable
  /// route (so the straight-line fallback draws instead).
  List<LatLng> get _roadPoints => (route?.polyline ?? const [])
      .map((p) => LatLng(
            (p['lat'] as num?)?.toDouble() ?? 0,
            (p['lng'] as num?)?.toDouble() ?? 0,
          ))
      .toList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pickupPoint = _pickupPoint;
    final dropoffPoint = _dropoffPoint;
    final road = _roadPoints;
    // The straight line is the honest fallback: the request failed, or the
    // backend answered with its own estimate.
    final useFallback = road.length < 2 || (route?.isEstimate ?? false);
    final straight = <LatLng>[?pickupPoint, ?dropoffPoint];

    final polylines = <Polyline>[
      if (straight.length == 2)
        Polyline(
          points: straight,
          strokeWidth: 2,
          color: Colors.grey,
          pattern: StrokePattern.dashed(segments: const [12, 8]),
        ),
      if (!useFallback)
        Polyline(
          points: road,
          strokeWidth: 5,
          color: Colors.blue,
        ),
    ];

    final focus = <LatLng>[
      if (driverPosition != null) LatLng(driverPosition!.lat, driverPosition!.lng),
      ?pickupPoint,
      ?dropoffPoint,
    ];
    final initialCenter = driverPosition != null
        ? LatLng(driverPosition!.lat, driverPosition!.lng)
        : (pickupPoint ?? const LatLng(9.9281, -84.0907));
    if (focus.length >= 2) {
      onFit(focus, '${stage.name}:${route?.fetchedAt.millisecondsSinceEpoch}');
    }

    final tile = ref.watch(tripMapTileProvider);
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: 13,
      ),
      children: [
        ?tile,
        PolylineLayer(polylines: polylines),
        MarkerLayer(
          markers: [
            if (pickupPoint != null)
              Marker(
                point: pickupPoint,
                child: const Icon(Icons.location_pin, color: Colors.green),
              ),
            if (dropoffPoint != null)
              Marker(
                point: dropoffPoint,
                child: const Icon(Icons.flag, color: Colors.red),
              ),
            if (driverPosition != null)
              Marker(
                point: LatLng(driverPosition!.lat, driverPosition!.lng),
                child: const Icon(Icons.navigation, color: Colors.blue),
              ),
          ],
        ),
      ],
    );
  }
}

class _StageControls extends StatelessWidget {
  final TripStage stage;
  final Ride? ride;
  final RouteCache? route;
  final String? cancelledBy;
  final bool canCancel;
  final VoidCallback onAdvance;
  final VoidCallback onCancel;
  final VoidCallback onComplete;
  final VoidCallback onFinish;

  const _StageControls({
    required this.stage,
    required this.ride,
    required this.route,
    required this.cancelledBy,
    required this.canCancel,
    required this.onAdvance,
    required this.onCancel,
    required this.onComplete,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    // The descriptive block always lives in a scroll view so a short or
    // landscape viewport can never overflow the panel; the action buttons stay
    // pinned to the bottom.
    if (stage == TripStage.cancelled) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Trip cancelled',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    cancelledBy == null || cancelledBy!.isEmpty
                        ? 'The trip was cancelled.'
                        : 'Cancelled by ${cancelledBy == 'rider' ? 'the rider' : cancelledBy!}.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          FilledButton(
            key: const Key('trip-done-button'),
            onPressed: onFinish,
            child: const Text('Back to home'),
          ),
        ],
      );
    }

    if (stage == TripStage.post) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Trip completed',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          _fareRow(context, 'Base fare', ride?.baseFare),
                          _fareRow(context, 'Distance', ride?.distanceFare),
                          _fareRow(context, 'Time', ride?.timeFare),
                          const Divider(height: 16),
                          _fareRow(
                            context,
                            'Total',
                            ride?.totalFare,
                            bold: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          FilledButton(
            key: const Key('trip-done-button'),
            onPressed: onFinish,
            child: const Text('Back to home'),
          ),
        ],
      );
    }

    final target = switch (stage) {
      TripStage.driving => ride?.dropoffAddress ?? 'Dropoff',
      _ => ride?.pickupAddress ?? 'Pickup',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  switch (stage) {
                    TripStage.pre => 'Waiting for the trip to start',
                    TripStage.enrouteToPickup => 'Drive to the pickup',
                    TripStage.arrived => 'Arrived at the pickup',
                    TripStage.driving => 'Driving to the dropoff',
                    TripStage.post => 'Trip completed',
                    TripStage.cancelled => 'Trip cancelled',
                  },
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(target, style: Theme.of(context).textTheme.bodyMedium),
                if (route != null && route!.distance > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    _legSummary(route!),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // One primary button per stage, matching the server's transition map.
        switch (stage) {
          TripStage.enrouteToPickup => FilledButton(
              key: const Key('trip-primary-button'),
              onPressed: onAdvance,
              child: const Text('Arrived at pickup'),
            ),
          TripStage.arrived => FilledButton(
              key: const Key('trip-primary-button'),
              onPressed: onAdvance,
              child: const Text('Start trip'),
            ),
          TripStage.driving => FilledButton(
              key: const Key('trip-primary-button'),
              onPressed: onComplete,
              child: const Text('Complete Trip'),
            ),
          // `pending` has no driver-side transition, and there is nothing to
          // drive at all without a ride.
          TripStage.pre => ride == null
              ? const SizedBox.shrink()
              : OutlinedButton(
                  key: const Key('trip-primary-button'),
                  onPressed: null,
                  child: const Text('Accept the offer to start'),
                ),
          TripStage.post || TripStage.cancelled =>
            const SizedBox.shrink(),
        },
        const SizedBox(height: 8),
        if (canCancel)
          OutlinedButton(
            key: const Key('trip-cancel-button'),
            onPressed: onCancel,
            child: const Text('Cancel trip'),
          )
        else if (ride != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Rider can cancel from here',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  Widget _fareRow(BuildContext context, String label, double? amount,
      {bool bold = false}) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: style),
        Text(
          amount == null ? '—' : '\$${amount.toStringAsFixed(2)}',
          style: style,
        ),
      ],
    );
  }

  static String _legSummary(RouteCache route) {
    final km = (route.distance / 1000).toStringAsFixed(1);
    final minutes = (route.duration / 60).ceil();
    final prefix = route.isEstimate ? 'Estimated ' : '';
    return '$prefix$km km · about $minutes min';
  }
}
