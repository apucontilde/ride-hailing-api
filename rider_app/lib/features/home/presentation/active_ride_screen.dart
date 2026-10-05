import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import '../../../core/utils/location_helper.dart';
import '../model/driver.dart';
import '../model/fare.dart';
import '../data/ride_status_provider.dart';
import '../data/home_provider.dart';
import '../data/location_ping_service.dart';
import '../data/ride_provider.dart';
import '../data/driver_tracking_provider.dart';
import '../data/trip_eta.dart';
import '../data/trip_route_provider.dart';
import 'rating_prompt_dialog.dart';

class ActiveRideScreen extends ConsumerStatefulWidget {
  const ActiveRideScreen({super.key});

  @override
  ConsumerState<ActiveRideScreen> createState() => _ActiveRideScreenState();
}

class _ActiveRideScreenState extends ConsumerState<ActiveRideScreen>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  LatLng? _riderPosition;
  StreamSubscription<dynamic>? _positionSubscription;
  LocationPingService? _pingService;
  /// Read once in `initState` for the same reason as `_pingService`: `ref` is
  /// unusable from `dispose()`, and the tracking tick must be cancelled there.
  late final DriverTrackingNotifier _tracker;

  /// The active trip's road route and its refresh tick; also read once in
  /// `initState` so `dispose()` can stop the timer.
  late final TripRouteNotifier _tripRoute;

  /// `MapController.move` before `FlutterMap` has built throws
  /// `LateInitializationError`; the post-frame callback is the earliest point at
  /// which the controller is usable.
  bool _mapReady = false;
  bool _completionHandled = false;
  bool _leaving = false;
  String? _detailRequestedFor;

  @override
  void initState() {
    super.initState();
    // The flow route is outside the shell, so `HomeScreen` is disposed when the
    // trip starts. Re-acquire the ping lease here (and in `DriverMatchingScreen`)
    // so the rider keeps streaming their position for the matching wait and the
    // whole live trip; the service's lease count keeps this from racing home's
    // `dispose`.
    WidgetsBinding.instance.addObserver(this);
    _pingService = ref.read(locationPingServiceProvider);
    _pingService!.start();
    _tracker = ref.read(driverTrackingProvider.notifier);
    _tripRoute = ref.read(tripRouteProvider.notifier);
    _initRiderLocation();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapReady = true;
      // LC-4: the HTTP half of live tracking. Arms immediately; the first
      // `GET /drivers/:id/location` only fires once the WS has been silent for
      // 10 s. `attach` supplies the driver id as soon as the accept event lands
      // (the `select` listener in `build` covers later changes; this call covers
      // an accept that arrived before the screen mounted — `WidgetRef.listen` has
      // no `fireImmediately`).
      _tracker
        ..attach(ref.read(rideStatusProvider).driver?.id)
        ..start();
      // `[ontrip]`: the active trip's road route + live refresh. The `select`
      // listeners in `build` cover later ride/destination changes; this call
      // covers a ride that was already active when the screen mounted.
      _tripRoute.start();
      final rideId = ref.read(rideStatusProvider).rideId;
      if (rideId != null) unawaited(_tripRoute.load(rideId));
      unawaited(_seedRatedRideIds());
      unawaited(_ensureRideDetail());
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

  void _initRiderLocation() {
    try {
      _positionSubscription = LocationHelper.getPositionStream().listen(
        (position) {
          if (mounted) {
            setState(() {
              _riderPosition = LatLng(position.latitude, position.longitude);
            });
          }
        },
        onError: (Object error, StackTrace stackTrace) {},
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingService?.stop();
    _positionSubscription?.cancel();
    // LC-4: never leave a 5 s driver-location tick running behind a disposed
    // screen.
    _tracker.stop();
    // `[ontrip]`: neither may the trip-route refresh tick outlive the screen.
    _tripRoute.stop();
    super.dispose();
  }

  /// LC-3 item 2 — resolve the ride id (WS `ride_id` or the current-ride poll,
  /// both of which land in `RideState.rideId`) and pull the authoritative
  /// `GET /rides/:id`, then merge it into the live state.
  ///
  /// Idempotent per ride id: `RideStatus` changes (accept → arrived → on trip)
  /// all re-enter here, and only the first call for a given ride is sent.
  Future<void> _ensureRideDetail() async {
    final rideId = ref.read(rideStatusProvider).rideId;
    if (rideId == null || _detailRequestedFor == rideId) return;
    _detailRequestedFor = rideId;
    final detail =
        await ref.read(rideDetailProvider.notifier).fetchRide(rideId);
    if (!mounted || detail == null) return;
    ref.read(rideStatusProvider.notifier).applyRideDetail(detail);
  }

  /// Seed the already-rated ride ids from `GET /rider/ratings` so a ride scored
  /// on another device is not re-prompted. Failure is non-fatal: the worst case
  /// is one redundant prompt, and a duplicate score is swallowed anyway.
  Future<void> _seedRatedRideIds() async {
    try {
      final rated = await ref.read(riderRatedRideIdsProvider.future);
      ref.read(rideDetailProvider.notifier).seedRatedRideIds(rated);
    } catch (_) {
      // Non-fatal — the rating POST still guards itself.
    }
  }

  Future<void> _cancelRide() async {
    final rideId = ref.read(rideStatusProvider).rideId;
    if (rideId == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Cancel this ride?'),
          content: const Text('Are you sure you want to cancel this ride?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Keep Ride'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Yes, Cancel'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    await ref.read(rideCreationProvider.notifier).cancelRide(rideId);
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
    context.go('/home');
  }

  void _centerOnDriver(DriverLocation location) {
    if (!_mapReady) return;
    try {
      _mapController.move(LatLng(location.lat, location.lng),
          _mapController.camera.zoom);
    } catch (_) {
      // The map camera is not ready yet; the next fix re-centers.
    }
  }

  /// LC-3 item 3/4 — the completion flow: real receipt, then the rating prompt.
  /// Runs at most once per trip (the WS `completed` and the `GET /rides/current`
  /// poll can both report it).
  Future<void> _handleCompletion(RideState next) async {
    if (_completionHandled) return;
    _completionHandled = true;

    final rideId = next.rideId;
    final fare = rideId == null
        ? next.fare
        : await ref
            .read(rideDetailProvider.notifier)
            .resolveFare(rideId, wsFare: next.fare);
    if (!mounted) return;

    await _showReceiptDialog(fare, fromWs: next.fare != null);
    if (!mounted) return;
    await _promptRating(rideId);
  }

  /// The fare breakdown. [fromWs] records which channel answered so the dialog
  /// can say where the numbers came from instead of implying a receipt was
  /// fetched either way.
  Future<void> _showReceiptDialog(Fare? fare, {required bool fromWs}) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          key: const ValueKey<String>('ride-receipt-dialog'),
          title: const Text('Ride receipt'),
          content: fare == null
              ? const Text('The fare breakdown for this ride is not available.')
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fareRow('Base fare', fare.baseFare),
                    _fareRow('Distance fare', fare.distanceFare),
                    _fareRow('Time fare', fare.timeFare),
                    _fareRow('Surge multiplier', null,
                        suffix: '×${fare.surgeMultiplier.toStringAsFixed(2)}'),
                    const Divider(),
                    _fareRow('Total', fare.total, emphasise: true),
                    const SizedBox(height: 12),
                    Text(
                      fromWs
                          ? 'Fare from your live trip.'
                          : 'Fare from the ride receipt.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _fareRow(String label, double? amount,
      {String? suffix, bool emphasise = false}) {
    final style = TextStyle(
      fontSize: emphasise ? 16 : 14,
      fontWeight: emphasise ? FontWeight.bold : FontWeight.normal,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(
            suffix ?? _formatFare(amount ?? 0),
            style: style,
          ),
        ],
      ),
    );
  }

  static String _formatFare(double value) => '\$${value.toStringAsFixed(2)}';

  /// LC-3 item 4 — the 1–5★ prompt, skipped when the ride is already scored.
  Future<void> _promptRating(String? rideId) async {
    if (rideId == null) {
      _goHome();
      return;
    }
    final state = ref.read(rideDetailProvider);
    if (!state.canRate(rideId)) {
      _goHome();
      return;
    }
    await showDialog<RatingOutcome>(
      context: context,
      builder: (dialogContext) => RatingPromptDialog(rideId: rideId),
    );
    _goHome();
  }

  void _goHome() {
    if (_leaving) return;
    _leaving = true;
    if (mounted) context.go('/home');
  }

  /// Manual receipt access from the driver sheet (LC-3 item 3).
  Future<void> _showReceiptOnTap() async {
    final rideId = ref.read(rideStatusProvider).rideId;
    final state = ref.read(rideStatusProvider);
    final fare = rideId == null
        ? state.fare
        : await ref
            .read(rideDetailProvider.notifier)
            .resolveFare(rideId, wsFare: state.fare);
    if (!mounted) return;
    await _showReceiptDialog(fare, fromWs: state.fare != null);
  }

  @override
  Widget build(BuildContext context) {
    final rideState = ref.watch(rideStatusProvider);
    final tripRoute = ref.watch(tripRouteProvider);

    // LC-4: the driver id from the accepted payload drives the
    // `GET /drivers/:id/location` fallback. `initState` attaches the id that is
    // already known; this listener picks up every later change.
    ref.listen<String?>(
      rideStatusProvider.select((state) => state.driver?.id),
      (previous, next) =>
          _tracker.attach(next),
    );

    // Every fix — WS or polled HTTP — restarts the silence window and re-centers.
    ref.listen<DriverLocation?>(
      rideStatusProvider.select((state) => state.driverLocation),
      (previous, next) {
        if (next == null || identical(previous, next)) return;
        _tracker.noteWsLocation(next);
        _centerOnDriver(next);
      },
    );

    // `[ontrip]`: a ride id that lands after mount (a create that finished
    // while the screen was already up) starts the route.
    ref.listen<String?>(
      rideStatusProvider.select((state) => state.rideId),
      (previous, next) {
        if (next == null || next == previous) return;
        _tripRoute.start();
        unawaited(_tripRoute.load(next));
      },
    );

    // `[ontrip]`: a destination/stops change is pushed as a fresh
    // `ride.updated` payload in `RideState.rideData`. The client re-reads the
    // itinerary and re-requests the route rather than waiting for a server
    // re-route.
    ref.listen<Map<String, dynamic>?>(
      rideStatusProvider.select((state) => state.rideData),
      (previous, next) {
        final rideId = ref.read(rideStatusProvider).rideId;
        if (next == null || rideId == null || identical(previous, next)) return;
        unawaited(_tripRoute.load(rideId));
      },
    );

    // Handle ride completion / cancellation
    ref.listen<RideState>(rideStatusProvider, (previous, next) {
      if (next.status == RideStatus.completed) {
        // Nothing left to track; stop before the dialogs open.
        _tracker.stop();
        _tripRoute.stop();
        unawaited(_ensureRideDetail());
        unawaited(_handleCompletion(next));
      } else if (next.status == RideStatus.cancelled) {
        _tracker.stop();
        _tripRoute.stop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride cancelled successfully')),
        );
        context.go('/home');
      } else {
        // The id can land on any non-terminal transition (arrived, on trip).
        unawaited(_ensureRideDetail());
      }
    });

    // LC-4: the typed `RideState.driverLocation` — the invented
    // `driver_lat`/`driver_lng` payload keys are gone.
    final driverLocation = rideState.driverLocation;
    final driverPosition = driverLocation == null
        ? null
        : LatLng(driverLocation.lat, driverLocation.lng);

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _riderPosition ?? const LatLng(9.9281, -84.0907),
              initialZoom: 15.0,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.rider.app',
                tileProvider: NetworkTileProvider(
                  headers: {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
                  },
                ),
              ),
              // `[ontrip]`: the server's road route for the trip. A ready route
              // is solid; an `is_estimate` route is grey + dashed so it can
              // never read as road following. A failed route draws nothing —
              // the banner below is the only surface, so an outage cannot
              // become a confident straight line.
              if (tripRoute.polyline.length >= 2)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: tripRoute.polyline,
                      color: tripRoute.hasRoadRoute
                          ? Colors.blue
                          : Colors.grey,
                      strokeWidth: 4.0,
                      pattern: tripRoute.hasRoadRoute
                          ? const StrokePattern.solid()
                          : StrokePattern.dashed(segments: const [12, 8]),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (_riderPosition != null)
                    Marker(
                      point: _riderPosition!,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.my_location, color: Colors.blue, size: 40),
                    ),
                  if (driverPosition != null)
                    Marker(
                      point: driverPosition,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.directions_car, color: Colors.black, size: 40),
                    ),
                ],
              ),
            ],
          ),
          if (tripRoute.isEstimate || tripRoute.hasError)
            Positioned(
              top: 8,
              left: 16,
              right: 16,
              child: SafeArea(child: _buildRouteBanner(tripRoute)),
            ),
          _buildDriverInfoSheet(rideState, driverPosition),
        ],
      ),
    );
  }

  /// The one place an estimate or a failure is surfaced. An estimate keeps the
  /// API's (straight) geometry but is labeled; a failure has no geometry and
  /// offers a Retry.
  Widget _buildRouteBanner(TripRouteState route) {
    final estimate = route.isEstimate;
    final title = estimate ? 'Estimated route' : 'Route unavailable';
    final message = route.message;
    return Material(
      key: ValueKey<String>(
        estimate ? 'trip-route-estimate' : 'trip-route-error',
      ),
      elevation: 3,
      borderRadius: BorderRadius.circular(12),
      color: estimate ? const Color(0xFFFFF8E1) : const Color(0xFFFFEBEE),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              estimate ? Icons.warning_amber_rounded : Icons.error_outline,
              size: 20,
              color: estimate ? Colors.orange[800] : Colors.red[700],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (message != null && message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[800],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (!estimate)
              TextButton(
                onPressed: () {
                  final rideId = ref.read(rideStatusProvider).rideId;
                  if (rideId != null) unawaited(_tripRoute.load(rideId));
                },
                child: const Text('Retry'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDriverInfoSheet(RideState rideState, LatLng? driverPosition) {
    // LC-4: typed `RideState.driver` — the invented `driver_name`/`car_model`
    // string reads are gone.
    final driver = rideState.driver;
    final driverName =
        (driver?.firstName.isNotEmpty ?? false) ? driver!.firstName : 'Your driver';
    final photoUrl = driver?.photoUrl;
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    final vehicleLine = _vehicleLine(driver?.vehicle);
    // The accept payload's `driver.rating` parses to 0.0 for a driver with no
    // ratings yet — a zero average is not a zero-star driver.
    final ratingLine = driver == null
        ? null
        : (driver.rating <= 0 ? 'New driver' : driver.rating.toStringAsFixed(1));
    final statusText = _getStatusText(rideState.status);
    // `[ontrip]`: the live ETA is driven by the typed `RideState.etaSeconds`.
    // `etaLabel` returns null for the backend's 300 s placeholder, so an
    // unknown ETA is labeled, never rounded into a fake "5 min".
    final eta = etaLabel(rideState.etaSeconds);
    final etaText = eta == null ? 'ETA unavailable' : 'ETA $eta';

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [
            BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, -2)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.grey,
                  // LC-4: the typed `photo_url`. A photo that 404s (or is
                  // unreachable) must not take the trip screen down — the
                  // `Icon` child below is the fallback.
                  backgroundImage:
                      hasPhoto ? NetworkImage(photoUrl) : null,
                  onBackgroundImageError: hasPhoto ? (_, _) {} : null,
                  child: const Icon(Icons.person, color: Colors.white, size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        driverName,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      if (vehicleLine != null)
                        Text(
                          vehicleLine,
                          style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                        ),
                      if (ratingLine != null)
                        Text(
                          '★ $ratingLine',
                          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(statusText),
                  backgroundColor: Colors.blue[50],
                  labelStyle: TextStyle(color: Colors.blue[700], fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.schedule, size: 16, color: Colors.grey[700]),
                const SizedBox(width: 6),
                Text(
                  etaText,
                  key: const ValueKey<String>('trip-eta'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[800],
                  ),
                ),
              ],
            ),
            if (driverPosition != null) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _showReceiptOnTap,
                  child: const Text('View receipt'),
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _cancelRide,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red[50],
                  foregroundColor: Colors.red,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text('Cancel Ride'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// `"White Toyota Corolla · AB123CD"` from the typed [DriverVehicle]; `null`
  /// when the accept payload carried no vehicle (never an invented
  /// "Unknown Vehicle").
  String? _vehicleLine(DriverVehicle? vehicle) {
    if (vehicle == null) return null;
    final descriptor = [vehicle.color, vehicle.make, vehicle.model]
        .where((part) => part.isNotEmpty)
        .join(' ');
    final parts = [
      if (descriptor.isNotEmpty) descriptor,
      if (vehicle.plateNumber.isNotEmpty) vehicle.plateNumber,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  String _getStatusText(RideStatus status) {
    switch (status) {
      case RideStatus.driverApproaching:
        return 'Driver Approaching';
      case RideStatus.onTrip:
        return 'On Trip';
      case RideStatus.completed:
        return 'Completed';
      default:
        return 'Matching';
    }
  }
}
