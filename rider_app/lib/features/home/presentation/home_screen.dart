import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/home_provider.dart';
import '../data/home_route_preview.dart';
import '../data/location_ping_service.dart';
import '../data/location_service.dart';
import '../data/multi_leg_route_provider.dart';
import '../data/pickup_memory_provider.dart';
import '../data/trip_return.dart';
import '../model/place.dart';
import 'nearby_drivers_chip.dart';
import 'ride_estimate_sheet.dart';
import 'stop_list.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({
    super.key,
    this.initialPickup,
    this.initialDestination,
    this.pickupMemory,
  });

  /// Seeds the pickup pin instead of resolving it from the platform location
  /// channel. Production leaves this `null`; the widget tests use it to reach
  /// the route preview without a live geolocator.
  final Place? initialPickup;

  /// Seeds the destination pin, so a test can land on the route preview
  /// without driving the `/location-search` flow.
  final Place? initialDestination;

  /// Seeds the pickup-return intent instead of consuming the global
  /// [pickupMemoryProvider]. Production leaves this `null`; the widget tests use
  /// it to drive a restore/reload without a live geolocator.
  final PickupMemory? pickupMemory;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  /// Fallback map/search-bias center when neither a pickup nor a device fix
  /// exists. It biases the place search only — it is never written into
  /// `_pickupLocation` or sent to the API.
  static const LatLng _defaultMapCenter = LatLng(9.9281, -84.0907);

  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  Place? _pickupLocation;
  Place? _destination;

  /// The last resolved device-location state, driving the persistent notice.
  LocationAvailability? _locationStatus;

  /// Ordered intermediate stops. Order in this list **is** the itinerary; the
  /// final destination stays [_destination] (the API appends `dropoff_*` last).
  final List<Place> _stops = [];
  LocationPingService? _pingService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pickupLocation = widget.initialPickup;
    _destination = widget.initialDestination;
    _pingService = ref.read(locationPingServiceProvider);
    _pingService!.start();

    // The pickup memory outlives this screen, so read the pending return intent
    // here and restore only the pickup (never destination/stops). Provider
    // state cannot be mutated during `initState`, so the consume/reset is
    // deferred to the first post-frame callback.
    final PickupMemory returnIntent =
        widget.pickupMemory ?? ref.read<PickupMemory>(pickupMemoryProvider);
    final restore = returnIntent.restoreOnHome;
    if (restore == true && returnIntent.manualPickup != null) {
      _pickupLocation = returnIntent.manualPickup;
    }
    if (restore != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (widget.pickupMemory == null) {
          final memory = ref.read(pickupMemoryProvider.notifier);
          // A completed trip starts a fresh booking: drop the old pickup
          // instead of leaving it to resurface.
          if (restore) {
            memory.consumeReturn();
          } else {
            memory.clear();
          }
        }
        resetRideState(ref);
        if (restore && _pickupLocation != null) _fitItinerary();
      });
    }

    _initLocation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pingService?.stop();
    super.dispose();
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

  /// Fits the camera to the whole itinerary (pickup → stops → destination), so
  /// adding or moving a stop keeps every pin in frame. Falls back to centering
  /// when only one point exists.
  void _fitItinerary() {
    final points = <LatLng>[
      if (_pickupLocation != null)
        LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
      else
        ?_currentPosition,
      for (final stop in _stops) LatLng(stop.lat, stop.lng),
      if (_destination != null) LatLng(_destination!.lat, _destination!.lng),
    ];
    if (points.isEmpty) return;
    try {
      if (points.length == 1) {
        _mapController.move(points.first, 15.0);
        return;
      }
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.all(60),
          maxZoom: 16.0,
        ),
      );
    } catch (_) {
      // The map camera is not attached yet (e.g. the first location fix lands
      // before the first frame); a later frame frames the itinerary.
    }
  }

  /// The route-preview plan for the current pickup/stops/destination, or null
  /// when there is not yet an origin/destination pair.
  RoutePlan? _routePlan() {
    final pickup = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;
    if (pickup == null || _destination == null) return null;
    return RoutePlan(
      fromLat: pickup.latitude,
      fromLng: pickup.longitude,
      toLat: _destination!.lat,
      toLng: _destination!.lng,
      stops: [for (final stop in _stops) RouteWaypoint(stop.lat, stop.lng)],
    );
  }

  Future<void> _addStop() async {
    // The bias is the search request center only (pickup → device fix → map
    // center → default region). It is never written into `_pickupLocation`, so
    // a stop can be searched even with no device fix and no manual pickup.
    final bias = _searchBias();
    final place = await context.push<Place>(
      '/location-search',
      extra: {
        'hint': 'Add a stop',
        'lat': bias.latitude,
        'lng': bias.longitude,
      },
    );
    if (place != null && mounted) {
      setState(() => _stops.add(place));
      _fitItinerary();
    }
  }

  void _removeStop(int index) {
    if (index < 0 || index >= _stops.length) return;
    setState(() => _stops.removeAt(index));
    _fitItinerary();
  }

  void _reorderStops(int oldIndex, int newIndex) {
    setState(() => applyStopReorder(_stops, oldIndex, newIndex));
    _fitItinerary();
  }

  Future<void> _initLocation() async {
    final service = ref.read(locationServiceProvider);
    final availability = await service.requestAvailability();
    if (!mounted) return;
    setState(() => _locationStatus = availability);

    if (availability == LocationAvailability.granted) {
      final position = await service.getCurrentPosition();
      if (!mounted) return;
      if (position != null) {
        setState(() {
          _currentPosition = LatLng(position.latitude, position.longitude);
        });
        // Never yank the camera off a restored/chosen pickup. With a pickup
        // present the itinerary is framed on the restore/selection path
        // instead; only the pickup-less device-fix path recenters.
        if (_pickupLocation == null) {
          try {
            _mapController.move(_currentPosition!, 15.0);
          } catch (_) {
            // Camera not attached yet; the default center still applies.
          }
        }
      } else {
        _showSnackBar('Unable to get current location');
      }
      return;
    }

    _showSnackBar(
      'Location permission is required to request rides',
      duration: const Duration(seconds: 5),
    );
  }

  /// `showSnackBar` requires a registered `Scaffold`; production's shell owns
  /// the only one. A bare mount (widget test, or a future shell-less context)
  /// degrades to the persistent notice instead of asserting.
  void _showSnackBar(String message, {Duration? duration}) {
    if (Scaffold.maybeOf(context) == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration ?? const Duration(seconds: 4),
      ),
    );
  }

  /// The center used to bias `/places/autocomplete`: the chosen pickup, else the
  /// device fix, else the visible map center, else the default region constant.
  /// It is a search bias only — it is never written into `_pickupLocation`.
  LatLng _searchBias() {
    if (_pickupLocation != null) {
      return LatLng(_pickupLocation!.lat, _pickupLocation!.lng);
    }
    if (_currentPosition != null) return _currentPosition!;
    try {
      return _mapController.camera.center;
    } catch (_) {
      return _defaultMapCenter;
    }
  }

  /// Clears a manual pickup so the device fix (`_currentPosition`) takes over
  /// again. When there is no fix this simply removes the pickup.
  void _clearManualPickup() {
    setState(() => _pickupLocation = null);
    _fitItinerary();
  }

  @override
  Widget build(BuildContext context) {
    final routePlan = _routePlan();
    final routeAsync =
        routePlan != null ? ref.watch(multiLegRouteProvider(routePlan)) : null;
    // One derivation feeds both the map and the info row, so they can never
    // disagree about what is drawn (the old `when(error:)` drew a straight line
    // while the row still showed the stale distance).
    final preview = HomeRoutePreview.fromAsync(routeAsync);

    // Body-only: the shell (`RiderShell`, wired in `core/router/app_router.dart`)
    // owns the single `Scaffold` + drawer. Keeping no `Scaffold` here is what
    // makes the overlay toggle's `Scaffold.of(context)` open the shell drawer.
    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _currentPosition ?? _defaultMapCenter,
            initialZoom: 15.0,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.rider.app',
              tileProvider: NetworkTileProvider(
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
                },
              ),
            ),
            // `[ontrip]` parity: only the API's own geometry is ever drawn. A
            // ready route is solid blue; an API-flagged estimate is grey +
            // dashed so it cannot read as road following; a failure draws
            // nothing at all (the info row is the only surface).
            if (preview.polyline.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: preview.polyline,
                    color: preview.hasRoadRoute
                        ? AppColors.routeReady
                        : AppColors.routeEstimate,
                    strokeWidth: 4.0,
                    pattern: preview.hasRoadRoute
                        ? const StrokePattern.solid()
                        : StrokePattern.dashed(segments: const [12, 8]),
                  ),
                ],
              ),
            if (_currentPosition != null ||
                _pickupLocation != null ||
                _stops.isNotEmpty ||
                _destination != null)
              MarkerLayer(
                markers: [
                  if (_currentPosition != null)
                    Marker(
                      point: _currentPosition!,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.my_location,
                        color: AppColors.info,
                        size: 40,
                      ),
                    ),
                  if (_pickupLocation != null)
                    Marker(
                      point: LatLng(_pickupLocation!.lat, _pickupLocation!.lng),
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_on,
                        color: AppColors.success,
                        size: 40,
                      ),
                    ),
                  for (final stop in _stops)
                    Marker(
                      point: LatLng(stop.lat, stop.lng),
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.trip_origin,
                        color: AppColors.warning,
                        size: 32,
                      ),
                    ),
                  if (_destination != null)
                    Marker(
                      point: LatLng(_destination!.lat, _destination!.lng),
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_on,
                        color: AppColors.danger,
                        size: 40,
                      ),
                    ),
                ],
              ),
          ],
        ),
        // The inset is owned by the `SafeArea` alone: the old `Positioned`
        // added `MediaQuery.padding.top` *and* the `SafeArea` added it again,
        // so the button sat one status-bar height too low.
        Positioned(
          top: 8,
          left: 16,
          child: SafeArea(
            child: AppSidebarToggleButton(
              style: IconButton.styleFrom(
                backgroundColor: AppColors.surface,
                elevation: 2,
              ),
            ),
          ),
        ),
        _buildBottomSheet(preview),
        // The my-location control used to live on home's own `Scaffold`;
        // body-only means it moves into the map's overlay stack.
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: _initLocation,
            backgroundColor: AppColors.surface,
            child: const Icon(Icons.my_location, color: AppColors.info),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomSheet(HomeRoutePreview preview) {
    return DraggableScrollableSheet(
      initialChildSize: 0.25,
      minChildSize: 0.1,
      maxChildSize: 0.4,
      builder: (context, scrollController) {
        return AppBottomSheet(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.lg),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              const AppSheetHandle(
                margin: EdgeInsets.only(bottom: AppSpacing.lg),
              ),
              _buildNearbyDriversChip(),
              if (_showLocationNotice) ...[
                _buildLocationNotice(),
                const SizedBox(height: 12),
              ],
              _buildLocationField(
                icon: Icons.circle,
                iconColor: AppColors.success,
                hint: 'Pickup location',
                value:
                    _pickupLocation?.name ??
                    (_currentPosition != null ? 'Current location' : null),
                semanticsLabel: 'Pickup location',
                trailing: (_pickupLocation != null && _currentPosition != null)
                    ? TextButton(
                        onPressed: _clearManualPickup,
                        child: const Text('Use current location'),
                      )
                    : null,
                onTap: () async {
                  final bias = _searchBias();
                  final place = await context.push<Place>(
                    '/location-search',
                    extra: {
                      'hint': _currentPosition != null
                          ? 'Pickup location'
                          : 'Enter pickup location',
                      'lat': bias.latitude,
                      'lng': bias.longitude,
                    },
                  );
                  if (place != null && mounted) {
                    setState(() => _pickupLocation = place);
                    _fitItinerary();
                  }
                },
              ),
              const SizedBox(height: 12),
              _buildLocationField(
                icon: Icons.square,
                iconColor: AppColors.danger,
                hint: 'Where to?',
                value: _destination?.name,
                onTap: () async {
                  // The destination field always opens the search. With no
                  // pickup and no device fix the `_searchBias()` center only
                  // biases the request — it is never written into
                  // `_pickupLocation` or the booking.
                  final hasOrigin =
                      _pickupLocation != null || _currentPosition != null;
                  final bias = _searchBias();
                  final place = await context.push<Place>(
                    '/location-search',
                    extra: {
                      'hint': hasOrigin ? 'Where to?' : 'Enter destination',
                      'lat': bias.latitude,
                      'lng': bias.longitude,
                    },
                  );
                  if (place != null && mounted) {
                    setState(() => _destination = place);
                    _fitItinerary();
                  }
                },
              ),
              // A destination is enough to start an itinerary: stops can be
              // searched with a bias even before an origin exists (the booking
              // action still requires a pickup/fix).
              if (_destination != null) ...[
                const SizedBox(height: 8),
                StopList(
                  stops: _stops,
                  onAdd: _addStop,
                  onRemove: _removeStop,
                  onReorder: _reorderStops,
                ),
              ],
              const SizedBox(height: 16),
              _buildRouteInfo(preview),
              const SizedBox(height: 8),
              _buildRequestTripButton(),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNearbyDriversChip() {
    final center = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;
    if (center == null) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: NearbyDriversChip(center: center),
    );
  }

  Widget _buildLocationField({
    required IconData icon,
    required Color iconColor,
    required String hint,
    String? value,
    VoidCallback? onTap,
    Widget? trailing,
    String? semanticsLabel,
  }) {
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticsLabel,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: 14,
          ),
          decoration: BoxDecoration(
            color: AppColors.surfaceMuted,
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
          child: Row(
            children: [
              Icon(icon, color: iconColor, size: 16),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  value ?? hint,
                  style: AppTextStyles.subtitle.copyWith(
                    fontWeight: FontWeight.w400,
                    color: value != null ? null : AppColors.muted,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
      ),
    );
  }

  /// True when there is no device fix and the last location check did not grant
  /// access. The manual-entry notice keeps showing even after a manual pickup is
  /// chosen; it clears only once a device fix arrives.
  bool get _showLocationNotice =>
      _currentPosition == null &&
      _locationStatus != null &&
      _locationStatus != LocationAvailability.granted;

  /// The persistent explanation of a missing device fix, with the recovery
  /// affordance so the rider is never silently blocked. The search bias / map
  /// center is never offered here as a pickup.
  Widget _buildLocationNotice() {
    const message =
        'Location is off. Enter a pickup location, or enable location.';
    final status = _locationStatus;
    return Semantics(
      container: true,
      label: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.warningTint,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.warningBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.location_off,
                  size: 18,
                  color: AppColors.warning,
                ),
                const SizedBox(width: AppSpacing.sm),
                const Expanded(
                  child: Text(message, style: AppTextStyles.label),
                ),
              ],
            ),
            Row(
              children: [
                if (status == LocationAvailability.deniedPermanently)
                  TextButton(
                    onPressed: () =>
                        ref.read(locationServiceProvider).openAppSettings(),
                    child: const Text('Open settings'),
                  )
                else if (status == LocationAvailability.servicesDisabled)
                  TextButton(
                    onPressed: () =>
                        ref.read(locationServiceProvider).openLocationSettings(),
                    child: const Text('Open location settings'),
                  ),
                TextButton(
                  onPressed: _initLocation,
                  child: const Text('Try again'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRouteInfo(HomeRoutePreview preview) {
    // Surfaced for a first-failure (`unavailable`) *and* a retained route whose
    // refresh failed (`isStale`): the map keeps the road geometry, the row tells
    // the truth about the refresh.
    if (preview.hasError) {
      return AppErrorRow(
        message: preview.message ?? HomeRoutePreview.unavailableReason,
        onRetry: _retryRoute,
      );
    }

    // Loading draws no geometry; a quiet affordance keeps the sheet from
    // looking inert while the first route is in flight.
    if (preview.isLoading) {
      return Row(
        children: [
          Icon(Icons.route, size: 16, color: AppColors.muted),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Finding route…',
            style: AppTextStyles.body.copyWith(color: AppColors.mutedStrong),
          ),
        ],
      );
    }

    if (!preview.hasRoute) return const SizedBox.shrink();

    final distanceKm = preview.totalDistanceM / 1000;
    final minutes = (preview.totalDurationS / 60).round();
    final prefix = preview.isEstimate ? 'Estimated ' : '';

    return Row(
      children: [
        Icon(Icons.route, size: 16, color: AppColors.muted),
        const SizedBox(width: AppSpacing.sm),
        Text(
          '$prefix${distanceKm.toStringAsFixed(1)} km  •  ~$minutes min',
          style: AppTextStyles.body.copyWith(
            color: AppColors.mutedStrong,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  void _retryRoute() {
    final plan = _routePlan();
    if (plan == null) return;
    ref.invalidate(multiLegRouteProvider(plan));
  }

  Widget _buildRequestTripButton() {
    final rideState = ref.watch(rideCreationProvider);
    final canRequest =
        _destination != null &&
        (_pickupLocation != null || _currentPosition != null);
    final isLoading = rideState.isLoading;

    return AppButton(
      label: 'Request Trip',
      expand: true,
      isLoading: isLoading,
      onPressed: canRequest ? () => _showRideEstimates(_destination!) : null,
    );
  }

  Future<void> _showRideEstimates(Place destination) async {
    final pickupPos = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;

    if (pickupPos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not determine your location')),
      );
      return;
    }

    final args = PriceEstimateArgs(
      pickupLat: pickupPos.latitude,
      pickupLng: pickupPos.longitude,
      dropoffLat: destination.lat,
      dropoffLng: destination.lng,
      stops: [
        for (final stop in _stops)
          EstimateStop(lat: stop.lat, lng: stop.lng, address: stop.address),
      ],
    );

    try {
      final estimates = await ref.read(priceEstimatesProvider(args).future);
      if (!mounted) return;

      final selectedType = await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => RideEstimateSheet(
          estimates: estimates,
          pickupLat: pickupPos.latitude,
          pickupLng: pickupPos.longitude,
          dropoffLat: destination.lat,
          dropoffLng: destination.lng,
        ),
      );

      if (selectedType != null) {
        _createRide(destination, selectedType);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error fetching estimates: $e')));
      }
    }
  }

  Future<void> _createRide(Place destination, String vehicleType) async {
    final pickupPos = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;

    if (pickupPos == null) return;

    // Persist the pickup the booking actually used so it survives Home's
    // disposal during the trip; `null` records "started from the device fix".
    ref.read(pickupMemoryProvider.notifier).remember(_pickupLocation);

    await ref
        .read(rideCreationProvider.notifier)
        .createRide(
          pickupLat: pickupPos.latitude,
          pickupLng: pickupPos.longitude,
          pickupAddress: _pickupLocation?.address ?? 'Current Location',
          dropoffLat: destination.lat,
          dropoffLng: destination.lng,
          dropoffAddress: destination.address,
          vehicleType: vehicleType,
          stops: List<Place>.of(_stops),
        );

    if (!mounted) return;
    final rideState = ref.read(rideCreationProvider);
    if (rideState.rideId != null) {
      context.go('/driver-matching');
    } else if (rideState.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(rideState.error!)));
    }
  }
}
