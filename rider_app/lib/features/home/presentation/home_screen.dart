import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/home_provider.dart';
import '../data/home_route_preview.dart';
import '../data/location_ping_service.dart';
import '../data/multi_leg_route_provider.dart';
import '../model/place.dart';
import 'nearby_drivers_chip.dart';
import 'ride_estimate_sheet.dart';
import 'stop_list.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({
    super.key,
    this.initialPickup,
    this.initialDestination,
  });

  /// Seeds the pickup pin instead of resolving it from the platform location
  /// channel. Production leaves this `null`; the widget tests use it to reach
  /// the route preview without a live geolocator.
  final Place? initialPickup;

  /// Seeds the destination pin, so a test can land on the route preview
  /// without driving the `/location-search` flow.
  final Place? initialDestination;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  Place? _pickupLocation;
  Place? _destination;

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
    final origin = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;
    final place = await context.push<Place>(
      '/location-search',
      extra: {
        'hint': 'Add a stop',
        if (origin != null) 'lat': origin.latitude,
        if (origin != null) 'lng': origin.longitude,
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
    final hasPermission = await LocationHelper.requestPermission();
    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Location permission is required to request rides'),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    final position = await LocationHelper.getCurrentPosition();
    if (position != null && mounted) {
      setState(() {
        _currentPosition = LatLng(position.latitude, position.longitude);
      });
      _mapController.move(_currentPosition!, 15.0);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to get current location')),
      );
    }
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
            initialCenter: _currentPosition ?? const LatLng(9.9281, -84.0907),
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
                    color: preview.hasRoadRoute ? Colors.blue : Colors.grey,
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
                        color: Colors.blue,
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
                        color: Colors.green,
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
                        color: Colors.orange,
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
                        color: Colors.red,
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
                backgroundColor: Colors.white,
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
            backgroundColor: Colors.white,
            child: const Icon(Icons.my_location, color: Colors.blue),
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
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 10,
                offset: Offset(0, -2),
              ),
            ],
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              _buildNearbyDriversChip(),
              _buildLocationField(
                icon: Icons.circle,
                iconColor: Colors.green,
                hint: 'Pickup location',
                value:
                    _pickupLocation?.name ??
                    (_currentPosition != null ? 'Current location' : null),
                onTap: () async {
                  final origin = _pickupLocation != null
                      ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
                      : _currentPosition;
                  if (origin == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not determine your location'),
                      ),
                    );
                    return;
                  }
                  final place = await context.push<Place>(
                    '/location-search',
                    extra: {
                      'hint': 'Pickup location',
                      'lat': origin.latitude,
                      'lng': origin.longitude,
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
                iconColor: Colors.red,
                hint: 'Where to?',
                value: _destination?.name,
                onTap: () async {
                  final origin = _pickupLocation != null
                      ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
                      : _currentPosition;
                  if (origin == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not determine your location'),
                      ),
                    );
                    return;
                  }
                  final place = await context.push<Place>(
                    '/location-search',
                    extra: {
                      'hint': 'Where to?',
                      'lat': origin.latitude,
                      'lng': origin.longitude,
                    },
                  );
                  if (place != null && mounted) {
                    setState(() => _destination = place);
                    _fitItinerary();
                  }
                },
              ),
              if ((_pickupLocation != null || _currentPosition != null) &&
                  _destination != null) ...[
                const SizedBox(height: 8),
                StopList(
                  stops: _stops,
                  onAdd: _addStop,
                  onRemove: _removeStop,
                  onReorder: _reorderStops,
                ),
                if (_stops.isNotEmpty) _buildStopsFareNote(),
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
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 16),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value ?? hint,
                style: TextStyle(
                  color: value != null ? Colors.black : Colors.grey,
                  fontSize: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The fare-estimate honesty caveat.
  ///
  /// Waypoint-aware pricing is an API gap: `POST /rides` quotes
  /// `pickup → dropoff` only and `GET /estimates/price` takes no stops. The
  /// rider keeps seeing the API's single-leg number, never a fabricated
  /// stop-inclusive one, and this note names the limitation.
  Widget _buildStopsFareNote() {
    return Padding(
      key: const ValueKey<String>('stops-fare-note'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Stops are not included in the price estimate. The fare is based '
              'on pickup to the final destination.',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteInfo(HomeRoutePreview preview) {
    // Surfaced for a first-failure (`unavailable`) *and* a retained route whose
    // refresh failed (`isStale`): the map keeps the road geometry, the row tells
    // the truth about the refresh.
    if (preview.hasError) {
      return Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preview.message ?? HomeRoutePreview.unavailableReason,
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ),
          TextButton(
            onPressed: _retryRoute,
            child: const Text('Retry'),
          ),
        ],
      );
    }

    // Loading draws no geometry; a quiet affordance keeps the sheet from
    // looking inert while the first route is in flight.
    if (preview.isLoading) {
      return Row(
        children: [
          Icon(Icons.route, size: 16, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Text(
            'Finding route…',
            style: TextStyle(color: Colors.grey[700], fontSize: 14),
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
        Icon(Icons.route, size: 16, color: Colors.grey[600]),
        const SizedBox(width: 8),
        Text(
          '$prefix${distanceKm.toStringAsFixed(1)} km  •  ~$minutes min',
          style: TextStyle(
            color: Colors.grey[700],
            fontSize: 14,
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

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: canRequest && !isLoading
            ? () => _showRideEstimates(_destination!)
            : null,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Request Trip', style: TextStyle(fontSize: 16)),
      ),
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

    final coords = {
      'pickup_lat': pickupPos.latitude,
      'pickup_lng': pickupPos.longitude,
      'dropoff_lat': destination.lat,
      'dropoff_lng': destination.lng,
    };

    try {
      final estimates = await ref.read(priceEstimatesProvider(coords).future);
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
