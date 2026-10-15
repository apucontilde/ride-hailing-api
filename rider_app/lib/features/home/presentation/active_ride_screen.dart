import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/map/rider_map_tile.dart';
import '../model/driver.dart';
import '../model/fare.dart';
import '../model/place.dart';
import '../model/ride_estimate.dart';
import '../data/change_destination_provider.dart';
import '../data/current_ride_provider.dart';
import '../data/ride_status_provider.dart';
import '../data/home_provider.dart';
import '../data/location_ping_service.dart';
import '../data/ride_provider.dart';
import '../data/driver_tracking_provider.dart';
import '../data/driver_eta_provider.dart';
import '../data/trip_eta.dart';
import '../data/trip_return.dart';
import '../data/trip_route_provider.dart';
import 'rating_prompt_dialog.dart';

class ActiveRideScreen extends ConsumerStatefulWidget {
  const ActiveRideScreen({super.key});

  @override
  ConsumerState<ActiveRideScreen> createState() => _ActiveRideScreenState();
}

class _ActiveRideScreenState extends ConsumerState<ActiveRideScreen>
    with WidgetsBindingObserver {
  /// Fallback search-bias center when the trip has no pickup and there is no
  /// device fix. It biases the destination search only — it is never written
  /// into any booking/pickup/destination state.
  static const LatLng _defaultMapCenter = LatLng(9.9281, -84.0907);

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

  /// `[ontrip]` R1: the client-computed driver→pickup ETA. Read once in
  /// `initState` so `dispose()` can stop its tick.
  late final DriverEtaNotifier _driverEta;

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
    _driverEta = ref.read(driverEtaProvider.notifier);
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
        ..attach(ref.read(rideStatusProvider).effectiveDriverId)
        ..start();
      // `[ontrip]`: the active trip's road route + live refresh. The `select`
      // listeners in `build` cover later ride/destination changes; this call
      // covers a ride that was already active when the screen mounted.
      _tripRoute.start();
      final rideId = ref.read(rideStatusProvider).rideId;
      if (rideId != null) unawaited(_tripRoute.load(rideId));
      // `[ontrip]` R1: seed the client ETA for a ride already approaching.
      _driverEta.onRideState(ref.read(rideStatusProvider));
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
    // `[ontrip]` R1: nor the driver-ETA compute tick.
    _driverEta.stop();
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
  /// on another device is not re-prompted. This is only the fast path; a ride
  /// outside the walk's bound is resolved per-ride by
  /// [riderRideRatingStatusProvider]. Failure is non-fatal: the status provider
  /// stays `unknown` for unresolved rides and the rating POST guards itself.
  Future<void> _seedRatedRideIds() async {
    try {
      final seed = await ref.read(riderRatedRideIdsProvider.future);
      ref.read(rideDetailProvider.notifier).seedRatedRideIds(seed.rideIds);
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
    _goHomeAfterCancel();
  }

  /// `[multi]` — pick a new final destination, show a fresh estimate, and only
  /// `PUT /rides/:id/destination` once the rider confirms.
  ///
  /// The server mutates the ride and pushes `ride.updated`; the listener in
  /// [build] already re-reads `GET /rides/:id` and re-requests the route, so
  /// this flow deliberately does **not** re-route or reprice locally. Cancelling
  /// the confirmation leaves the ride, its fare and the driver untouched.
  Future<void> _changeDestination() async {
    final rideId = ref.read(rideStatusProvider).rideId;
    if (rideId == null) return;

    final bias = _searchBias();
    final place = await context.push<Place>(
      '/location-search',
      extra: {
        'hint': 'Where to?',
        'lat': bias.latitude,
        'lng': bias.longitude,
      },
    );
    if (place == null || !mounted) return;

    final estimate = await _estimateForDestination(place);
    if (!mounted) return;

    final confirmed = await _confirmChangeDestination(place, estimate);
    if (confirmed != true || !mounted) return;

    final changed = await ref
        .read(changeDestinationProvider.notifier)
        .changeDestination(
          rideId,
          lat: place.lat,
          lng: place.lng,
          address: place.address,
        );
    if (!mounted) return;

    final message = changed
        ? 'Destination updated'
        : ref.read(changeDestinationProvider).error ??
            'Failed to change destination';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// A fresh `POST /estimates/price` for `place` as the new dropoff, using the
  /// trip's ordered itinerary as the origin. Returns null when the estimate
  /// cannot be produced (no routeable pickup, an outage, or a malformed body) —
  /// the confirmation is still offered, honestly labeled.
  Future<RideEstimate?> _estimateForDestination(Place place) async {
    final tripRoute = ref.read(tripRouteProvider);
    final pickup = tripRoute.pickup ?? _pickupFromRideData();
    if (pickup == null) return null;

    final args = PriceEstimateArgs(
      pickupLat: pickup.latitude,
      pickupLng: pickup.longitude,
      dropoffLat: place.lat,
      dropoffLng: place.lng,
      stops: [
        for (final stop in tripRoute.stopPoints)
          EstimateStop(lat: stop.latitude, lng: stop.longitude),
      ],
    );
    try {
      final estimates = await ref.read(priceEstimatesProvider(args).future);
      return _pickEstimate(estimates, tripRoute.vehicleType);
    } catch (_) {
      // An estimate outage must not veto a core action.
      return null;
    }
  }

  /// The trip's pickup pin from the live ride data, for the cold-start shape
  /// (`/rides/current` carries `pickup_lat`/`pickup_lng`). Never fabricated.
  LatLng? _pickupFromRideData() {
    final data = ref.read(rideStatusProvider).rideData;
    final pickup = data?['pickup'];
    if (pickup is Map) {
      final lat = pickup['lat'];
      final lng = pickup['lng'];
      if (lat is num && lng is num) {
        return LatLng(lat.toDouble(), lng.toDouble());
      }
    }
    final lat = data?['pickup_lat'];
    final lng = data?['pickup_lng'];
    if (lat is num && lng is num) {
      return LatLng(lat.toDouble(), lng.toDouble());
    }
    return null;
  }

  /// The booked vehicle's estimate, or the first/only one when the booked type
  /// is unknown.
  RideEstimate? _pickEstimate(List<RideEstimate> estimates, String? vehicleType) {
    if (estimates.isEmpty) return null;
    if (vehicleType != null && vehicleType.isNotEmpty) {
      for (final estimate in estimates) {
        if (estimate.vehicleType == vehicleType) return estimate;
      }
    }
    return estimates.first;
  }

  Future<bool?> _confirmChangeDestination(
    Place place,
    RideEstimate? estimate,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          key: const ValueKey<String>('change-destination-dialog'),
          title: const Text('Change destination?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(place.address, style: AppTextStyles.body),
              const SizedBox(height: 12),
              if (estimate == null)
                Text(
                  'Estimate unavailable',
                  key: const ValueKey<String>('change-destination-no-estimate'),
                  style: AppTextStyles.label.copyWith(
                    color: AppColors.mutedStrong,
                  ),
                )
              else ...[
                Text(
                  'Estimated new fare: ${estimate.formattedTotal}'
                  '${_estimateDuration(estimate) == null ? '' : ' · ${_estimateDuration(estimate)}'}',
                  key: const ValueKey<String>('change-destination-estimate'),
                  style: AppTextStyles.subtitle,
                ),
                if (estimate.isEstimate)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Estimated fare — not fully road-routed',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.warningForeground,
                      ),
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                'Your final charge is recalculated from the distance actually '
                'driven — this is an estimate, not a guaranteed fare.',
                style: AppTextStyles.caption.copyWith(color: AppColors.muted),
              ),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey<String>('change-destination-cancel'),
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey<String>('change-destination-confirm'),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
  }

  /// `~N min` from the summed leg durations, or null when the endpoint returned
  /// no durations (the price endpoint carries no `eta_seconds`).
  String? _estimateDuration(RideEstimate estimate) {
    var seconds = 0;
    for (final leg in estimate.legs) {
      seconds += leg.durationS;
    }
    if (seconds <= 0) return null;
    return '~${(seconds / 60).ceil()} min';
  }

  /// The search center for a new destination: the trip's pickup, else the
  /// rider's last-known position, else the visible map center, else the default
  /// region constant. It biases `/places/autocomplete` only — it is never
  /// written into the booking or the destination, so a change-destination search
  /// always opens with a real bias and can never hit the blocking
  /// `'Enable location to search nearby'` branch (bug #21).
  LatLng _searchBias() {
    final pickup = ref.read(rideStatusProvider).rideData?['pickup'];
    if (pickup is Map) {
      final lat = pickup['lat'];
      final lng = pickup['lng'];
      if (lat is num && lng is num) {
        return LatLng(lat.toDouble(), lng.toDouble());
      }
    }
    if (_riderPosition != null) return _riderPosition!;
    try {
      return _mapController.camera.center;
    } catch (_) {
      return _defaultMapCenter;
    }
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
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.muted,
                      ),
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
    final style = emphasise ? AppTextStyles.fare : AppTextStyles.body;
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

  /// LC-3 item 4 — the 1–5★ prompt, skipped when the ride is already rated.
  ///
  /// The gate is [riderRideRatingStatusProvider], not the session-local set: a
  /// ride is only offered when the server (or the complete seed, or a per-ride
  /// `ride_id` lookup past the seed bound) says [RatingStatus.unrated]. A
  /// loading, failed, or unresolved seed is [RatingStatus.unknown] and never
  /// becomes a prompt.
  Future<void> _promptRating(String? rideId) async {
    if (rideId == null) {
      _goHome();
      return;
    }
    final status = await ref.read(riderRideRatingStatusProvider(rideId).future);
    if (!mounted) return;
    final state = ref.read(rideDetailProvider);
    if (!status.canRate || !state.canRate(rideId)) {
      _goHome();
      return;
    }
    await showRatingPrompt(context, rideId: rideId);
    _goHome();
  }

  void _goHome() {
    if (_leaving) return;
    _leaving = true;
    markTripReturn(ref, restorePickup: false);
    // Drop the poll's (now stale) active status so the router's restore
    // redirect cannot bounce a completed ride back to the trip.
    ref.read(currentRideProvider.notifier).reset();
    if (mounted) context.go('/home');
  }

  /// Cancel/terminal-cancel exit: unlike completion, the rider's pickup is kept
  /// so they can retry the same trip immediately.
  void _goHomeAfterCancel() {
    if (_leaving) return;
    _leaving = true;
    markTripReturn(ref, restorePickup: true);
    ref.read(currentRideProvider.notifier).reset();
    if (mounted) context.go('/home');
  }

  /// The overlay back arrow's handler: a live trip routes through the same
  /// cancel confirmation as the `Cancel Ride` button; a terminal state (the
  /// receipt/rating flow is already leaving) goes straight home. It never pops —
  /// this screen is reached with `go`, so `canPop` is false.
  void _handleBack() {
    final status = ref.read(rideStatusProvider).status;
    if (status == RideStatus.completed || status == RideStatus.cancelled) {
      _goHome();
    } else {
      _cancelRide();
    }
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
    // already known; this listener picks up every later change. `effectiveDriverId`
    // also covers a cold-start `/rides/current` payload, which carries
    // `driver_id` with no nested `driver` object.
    ref.listen<String?>(
      rideStatusProvider.select((state) => state.effectiveDriverId),
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
      // `[ontrip]` R1: recompute/stop the client ETA on every status or fix
      // change (it no-ops unless `driverApproaching`).
      _driverEta.onRideState(next);
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
        _goHomeAfterCancel();
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

    // The shared tile factory owns the `TileLayer`; this screen only supplies
    // the app's tile config and renders whatever it returns (null in tests).
    final tileConfig = ref.watch(riderMapTileConfigProvider);
    final tile = ref.watch(mapTileLayerProvider(tileConfig));

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
              ?tile,
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
                          ? AppColors.routeReady
                          : AppColors.routeEstimate,
                      strokeWidth: 4.0,
                      pattern: tripRoute.hasRoadRoute
                          ? const StrokePattern.solid()
                          : StrokePattern.dashed(segments: const [12, 8]),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  // `[ontrip]` R-3: the ordered itinerary pins the Home map
                  // already draws. Intermediate stops use Home's `trip_origin`
                  // vocabulary, the destination `location_on`; both are distinct
                  // from the rider/driver markers below.
                  for (final stop in tripRoute.stopPoints)
                    Marker(
                      point: stop,
                      width: 32,
                      height: 32,
                      child: const Icon(
                        Icons.trip_origin,
                        color: AppColors.warning,
                        size: 28,
                      ),
                    ),
                  if (tripRoute.dropoff != null)
                    Marker(
                      point: tripRoute.dropoff!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_on,
                        color: AppColors.danger,
                        size: 36,
                      ),
                    ),
                  if (_riderPosition != null)
                    Marker(
                      point: _riderPosition!,
                      width: 40,
                      height: 40,
                      child: const Icon(Icons.my_location, color: AppColors.info, size: 40),
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
              MapTileAttribution(config: tileConfig),
            ],
          ),
          if (tripRoute.isEstimate || tripRoute.hasError)
            Positioned(
              top: 8,
              left: 16,
              right: 16,
              child: SafeArea(child: _buildRouteBanner(tripRoute)),
            ),
          // The screen has no `AppBar` (body-only, edge-to-edge map), so the
          // back affordance floats over the map like Home's sidebar toggle.
          Positioned(
            top: 8,
            left: 16,
            child: SafeArea(
              child: AppBackButton(onPressed: _handleBack),
            ),
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
      elevation: AppElevation.banner,
      borderRadius: BorderRadius.circular(AppRadii.md),
      color: estimate ? AppColors.estimateBanner : AppColors.errorBanner,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.md, 10, AppSpacing.sm, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              estimate ? Icons.warning_amber_rounded : Icons.error_outline,
              size: 20,
              color: estimate
                  ? AppColors.warningForeground
                  : AppColors.dangerForeground,
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.label),
                  if (message != null && message.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        message,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.mutedStrong,
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

    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: AppBottomSheet(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSheetHandle(),
            const SizedBox(height: 20),
            Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundColor: AppColors.muted,
                  // LC-4: the typed `photo_url`. A photo that 404s (or is
                  // unreachable) must not take the trip screen down — the
                  // `Icon` child below is the fallback.
                  backgroundImage:
                      hasPhoto ? NetworkImage(photoUrl) : null,
                  onBackgroundImageError: hasPhoto ? (_, _) {} : null,
                  child: const Icon(
                    Icons.person,
                    color: AppColors.onPrimary,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(driverName, style: AppTextStyles.title),
                      if (vehicleLine != null)
                        Text(
                          vehicleLine,
                          style: AppTextStyles.body.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                      if (ratingLine != null)
                        Text(
                          '★ $ratingLine',
                          style: AppTextStyles.label.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
                AppStatusChip(label: statusText),
              ],
            ),
            const SizedBox(height: 12),
            _buildStatusDetail(rideState),
            _buildNearbyNotice(rideState),
            if (driverPosition != null) ...[
              const SizedBox(height: 16),
              AppButton(
                label: 'View receipt',
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: _showReceiptOnTap,
              ),
            ],
            if (isDestinationChangeable(rideState.status)) ...[
              const SizedBox(height: 16),
              _buildChangeDestinationButton(),
            ],
            const SizedBox(height: 16),
            AppButton(
              label: 'Cancel Ride',
              variant: AppButtonVariant.danger,
              expand: true,
              onPressed: _cancelRide,
            ),
          ],
        ),
      ),
    );
  }

  /// `[multi]` — the destination-change entry point, prominent once the rider is
  /// on the trip and lighter while waiting for the driver. It is only built for
  /// a changeable status (see [isDestinationChangeable]), so it is absent on a
  /// completed/cancelled ride.
  Widget _buildChangeDestinationButton() {
    final submitting = ref.watch(changeDestinationProvider).isSubmitting;
    return AppButton(
      key: const ValueKey<String>('change-destination-button'),
      label: 'Change destination',
      icon: Icons.edit_location_alt,
      expand: true,
      isLoading: submitting,
      onPressed: _changeDestination,
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

  /// The status-aware detail row under the driver card.
  ///
  /// `[ontrip]` D1: the arrival ETA is meaningful only while the driver is
  /// approaching. Once arrived, a countdown to an event that already happened is
  /// a lie, so it becomes an explicit arrived line; once on the trip the
  /// driver→pickup time is meaningless and the row is gone.
  Widget _buildStatusDetail(RideState rideState) {
    switch (rideState.status) {
      case RideStatus.driverApproaching:
        return Row(
          children: [
            const Icon(Icons.schedule, size: 16, color: AppColors.mutedStrong),
            const SizedBox(width: 6),
            Text(
              _etaText(rideState),
              key: const ValueKey<String>('trip-eta'),
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.mutedStrong,
              ),
            ),
          ],
        );
      case RideStatus.driverArrived:
        return Row(
          children: [
            const Icon(
              Icons.person_pin_circle,
              size: 16,
              color: AppColors.mutedStrong,
            ),
            const SizedBox(width: 6),
            Text(
              'Your driver has arrived',
              key: const ValueKey<String>('trip-arrived'),
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.mutedStrong,
              ),
            ),
          ],
        );
      case RideStatus.matching:
      case RideStatus.onTrip:
      case RideStatus.completed:
      case RideStatus.cancelled:
      case RideStatus.noDriverAvailable:
      case RideStatus.idle:
        return const SizedBox.shrink();
    }
  }

  /// The live arrival ETA, with distance when `/geo/eta` supplied one. The
  /// `300`-placeholder honesty is preserved by [etaLabel].
  String _etaText(RideState rideState) {
    final eta = etaLabel(rideState.etaSeconds);
    if (eta == null) return 'ETA unavailable';
    final distance = rideState.etaDistanceM;
    if (distance != null && distance > 0) {
      final km = (distance / 1000).toStringAsFixed(1);
      return '$km km · ETA $eta';
    }
    return 'ETA $eta';
  }

  /// `[arrival]` — the pre-arrival "driver is nearby" notice. Only shown while
  /// the server holds `accepted` **and** flagged `near_pickup`; the rider never
  /// invents "near". Cleared on the status transition by `RideStatusNotifier`.
  Widget _buildNearbyNotice(RideState rideState) {
    if (rideState.status != RideStatus.driverApproaching ||
        !rideState.nearPickup) {
      return const SizedBox.shrink();
    }
    final distance = rideState.nearPickupDistanceM;
    final distanceText = distance == null
        ? null
        : distance >= 1000
            ? '${(distance / 1000).toStringAsFixed(1)} km away'
            : '${distance.round()} m away';
    return Container(
      key: const ValueKey<String>('driver-nearby-notice'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.estimateBanner,
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.near_me,
            size: 16,
            color: AppColors.warningForeground,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              distanceText == null
                  ? 'Your driver is nearby'
                  : 'Your driver is nearby · $distanceText',
              style: AppTextStyles.label.copyWith(
                color: AppColors.warningForeground,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The status chip label. Exhaustive over [RideStatus] — no `default`, so a
  /// future status forces a copy decision instead of silently reading
  /// `Matching` (Known bug #29: `driverArrived` used to fall through to
  /// `Matching`).
  String _getStatusText(RideStatus status) {
    switch (status) {
      case RideStatus.matching:
        // Aligns with the matching screen's own copy.
        return 'Finding your driver';
      case RideStatus.driverApproaching:
        return 'Driver Approaching';
      case RideStatus.driverArrived:
        return 'Driver arrived';
      case RideStatus.onTrip:
        return 'On Trip';
      case RideStatus.completed:
        return 'Completed';
      case RideStatus.cancelled:
        return 'Cancelled';
      case RideStatus.noDriverAvailable:
        return 'No drivers found';
      case RideStatus.idle:
        return 'No active ride';
    }
  }
}
