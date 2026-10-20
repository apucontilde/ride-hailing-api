import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/map/rider_map_tile.dart';
import 'package:rider_app/core/platform/sheet_drag_handle.dart';
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

/// Session-only memory of the Home booking panel's chosen size (a fraction of
/// the available height). It is deliberately not persisted: a cold start opens
/// the panel at its default size again.
final homePanelSizeProvider = StateProvider<double>((ref) => 0.25);

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

  /// Drives the booking panel's snap and the map/FAB relayout.
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  /// The running panel size during a grabber drag, or `null` when no drag is in
  /// progress. The grabber drives [_sheetController] directly; it is the
  /// desktop/web mouse path only (the mobile touch path is the scroll drag).
  double? _sheetDragSize;

  /// The size the panel opens at, restored from [homePanelSizeProvider].
  late double _initialSize;

  /// The full height the Home body is laid out in, captured each frame. The
  /// panel fractions and the map's layout box are relative to it.
  double _availableHeight = 0;

  /// The content-driven max snap point, measured from the booking form.
  double _sheetMax = 0.9;

  /// Identifies the booking-form content so [_scheduleSheetMaxMeasure] can read
  /// its intrinsic height.
  final GlobalKey _sheetContentKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pickupLocation = widget.initialPickup;
    _destination = widget.initialDestination;
    _pingService = ref.read(locationPingServiceProvider);
    _pingService!.start();
    _initialSize = ref.read(homePanelSizeProvider);
    _sheetController.addListener(_onSheetChanged);

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
    _sheetController
      ..removeListener(_onSheetChanged)
      ..dispose();
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
  /// when only one point exists. Returns whether the camera moved.
  bool _fitItinerary() {
    final points = _itineraryPoints();
    if (points.isEmpty) return false;
    if (points.length == 1) {
      return centerMapCamera(_mapController, points.first, zoom: 15);
    }
    return fitMapCamera(
      _mapController,
      points,
      padding: _fitPadding(),
      maxZoom: 16,
    );
  }

  /// The itinerary pins in order: pickup (or the device fix), stops,
  /// destination. The device fix is a fallback origin only — it is never
  /// written into `_pickupLocation`.
  List<LatLng> _itineraryPoints() => <LatLng>[
    if (_pickupLocation != null)
      LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
    else
      ?_currentPosition,
    for (final stop in _stops) LatLng(stop.lat, stop.lng),
    if (_destination != null) LatLng(_destination!.lat, _destination!.lng),
  ];

  /// Keep every pin inside the shrinking visible map: the panel covers the
  /// bottom `panelPixels`, so the fit's bottom padding grows with it.
  EdgeInsets _fitPadding() {
    final availableHeight = _availableHeight;
    return EdgeInsets.fromLTRB(
      60,
      60,
      60,
      availableHeight <= 0
          ? 60
          : (_panelPixels(availableHeight) + 60).clamp(
              60.0,
              availableHeight * 0.7,
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

  /// Fits the drawable route: the API preview polyline when it has ≥ 2 points,
  /// else the itinerary pins. Returns whether the camera moved, so the shared
  /// locate button can advance its cycle.
  bool _fitRoute(HomeRoutePreview preview) {
    if (preview.polyline.length >= 2) {
      return fitMapCamera(
        _mapController,
        preview.polyline,
        padding: _fitPadding(),
        maxZoom: 16,
      );
    }
    return _fitItinerary();
  }

  /// Whether there is a route or an itinerary worth fitting. Moving markers
  /// alone (a GPS refresh) are not a route.
  bool _canFitRoute(HomeRoutePreview preview) =>
      preview.polyline.length >= 2 || _itineraryPoints().length >= 2;

  /// The last settled route discriminator (`ready`/`estimate`). A transient
  /// `loading`/`unavailable` preview does not clear it, so a locate press that
  /// re-keys the route-plan family (the device fix is the origin) does not look
  /// like a material route change.
  String? _settledRoutePhase;

  /// Material-route key: the 3-value route discriminator (`none`/`ready`/
  /// `estimate`, mirroring the driver's contract) + pickup/stops/destination
  /// coordinates. A device-fix refresh, a silent preview refresh or a
  /// same-endpoint reroute must not auto-fit or reset the button cycle.
  String _homeRouteKey(HomeRoutePreview preview) {
    String point(double lat, double lng) => '$lat,$lng';
    return <String>[
      _homeRoutePhase(preview),
      if (_pickupLocation != null)
        'p:${point(_pickupLocation!.lat, _pickupLocation!.lng)}',
      for (final stop in _stops) 's:${point(stop.lat, stop.lng)}',
      if (_destination != null)
        'd:${point(_destination!.lat, _destination!.lng)}',
    ].join('|');
  }

  /// The material route discriminator. Only a settled road/estimate route
  /// updates it; `none → ready` (the road route first arriving) is material and
  /// auto-fits once, while `ready → loading → ready` from a fix refresh is not.
  String _homeRoutePhase(HomeRoutePreview preview) {
    if (preview.isReady) {
      _settledRoutePhase = 'ready';
    } else if (preview.isEstimate) {
      _settledRoutePhase = 'estimate';
    }
    return _settledRoutePhase ?? 'none';
  }

  /// The locate press: re-resolve availability (keeping the persistent notice
  /// truthful), fetch a fresh fix, fall back to the cached one, then center.
  /// Never fabricates a point. [`_initLocation`] stays the startup path.
  Future<bool> _locateCurrentPosition() async {
    final service = ref.read(locationServiceProvider);
    final availability = await service.requestAvailability();
    if (!mounted) return false;
    setState(() => _locationStatus = availability);

    if (availability != LocationAvailability.granted) {
      _showSnackBar(
        'Location permission is required to request rides',
        duration: const Duration(seconds: 5),
      );
      return false;
    }

    final position = await service.getCurrentPosition();
    if (!mounted) return false;
    final fresh = position == null
        ? null
        : LatLng(position.latitude, position.longitude);
    final target = fresh ?? _currentPosition;
    if (target == null) {
      _showSnackBar('Unable to get current location');
      return false;
    }
    if (fresh != null) {
      setState(() => _currentPosition = fresh);
    }
    return centerMapCamera(_mapController, target);
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

  /// The panel's current size as a fraction, falling back to the opening size
  /// before the sheet has attached.
  double get _panelSize =>
      _sheetController.isAttached ? _sheetController.size : _initialSize;

  /// The panel's current height in logical pixels.
  double _panelPixels(double availableHeight) => availableHeight * _panelSize;

  /// The map's layout height: the space the panel does not cover.
  double _mapHeight(double availableHeight) =>
      (availableHeight * (1 - _panelSize)).clamp(0.0, availableHeight);

  /// The handle-only minimum: the 48 dp handle touch target plus the sheet's
  /// top padding, clamped to a sane floor on very tall surfaces.
  double _minSheetSize(double availableHeight) {
    if (availableHeight <= 0) return 0.06;
    const handlePx = 64.0;
    return (handlePx / availableHeight).clamp(0.06, 0.10);
  }

  /// Remembers the chosen panel size for the session so returning to Home
  /// restores it. Deferred to a frame callback: the controller can notify during
  /// layout, and a provider must not be written mid-build.
  void _onSheetChanged() {
    if (!mounted || !_sheetController.isAttached) return;
    final size = _sheetController.size;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(homePanelSizeProvider.notifier).state = size;
    });
  }

  /// The handle's accessible affordance: toggle between the handle-only minimum
  /// and the opening size. On desktop/web the handle also has a mouse-only drag
  /// recognizer (see [_buildSheetHandle]); on mobile the list-scroll path stays
  /// the only resize gesture, so the two never compete.
  void _togglePanelSize() {
    if (!_sheetController.isAttached) return;
    final minSize = _minSheetSize(_availableHeight);
    final target =
        _panelSize > (minSize + _initialSize) / 2 ? minSize : _initialSize;
    _sheetController.animateTo(
      target,
      duration: AppMotion.medium,
      curve: AppMotion.standard,
    );
  }

  void _onSheetHandleDragStart(DragStartDetails details) {
    if (!_sheetController.isAttached || _availableHeight <= 0) return;
    _sheetDragSize = _sheetController.size;
  }

  void _onSheetHandleDragUpdate(DragUpdateDetails details) {
    final dragSize = _sheetDragSize;
    if (dragSize == null ||
        !_sheetController.isAttached ||
        _availableHeight <= 0) {
      return;
    }
    final min = _minSheetSize(_availableHeight);
    final max = _sheetMax.clamp(_initialSize, 0.9).toDouble();
    // Dragging up has a negative `dy`, so the panel grows.
    final next = (dragSize - details.delta.dy / _availableHeight)
        .clamp(min, max)
        .toDouble();
    _sheetDragSize = next;
    _sheetController.jumpTo(next);
  }

  void _onSheetHandleDragEnd(DragEndDetails details) =>
      _settleSheetDrag(details.velocity.pixelsPerSecond.dy);

  /// A pointer leaving the window cancels the drag; settle at the nearest snap
  /// rather than leaving the panel mid-drag with stale state.
  void _onSheetHandleDragCancel() => _settleSheetDrag(0);

  /// The single end-of-drag landing for end and cancel: `jumpTo`/`animateTo`
  /// bypass the sheet's own `snapSizes`, so snap to `{min, initial, max}` here,
  /// honoring the fling direction.
  void _settleSheetDrag(double velocityDy) {
    if (_sheetDragSize == null ||
        !_sheetController.isAttached ||
        _availableHeight <= 0) {
      return;
    }
    final min = _minSheetSize(_availableHeight);
    final max = _sheetMax.clamp(_initialSize, 0.9).toDouble();
    final initial = _initialSize.clamp(min, max).toDouble();
    final size = _sheetController.size;
    final snaps = <double>[min, initial, max]..sort();
    double target;
    if (velocityDy.abs() > kMinFlingVelocity) {
      target = velocityDy < 0
          ? snaps.firstWhere((s) => s > size, orElse: () => max)
          : snaps.lastWhere((s) => s < size, orElse: () => min);
    } else {
      target = snaps.reduce(
        (a, b) => (a - size).abs() <= (b - size).abs() ? a : b,
      );
    }
    _sheetController.animateTo(
      target,
      duration: AppMotion.medium,
      curve: AppMotion.standard,
    );
    _sheetDragSize = null;
  }

  /// Measures the booking form (inside a scroll view, so the child gets an
  /// unbounded main axis) and sets the max snap point to fit it, capped at 0.9.
  void _scheduleSheetMaxMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _availableHeight <= 0) return;
      final contentContext = _sheetContentKey.currentContext;
      final box = contentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final insets = MediaQuery.viewInsetsOf(contentContext!).bottom;
      final contentHeight = box.size.height + AppSpacing.lg * 2 + insets;
      final target = (contentHeight / _availableHeight).clamp(_initialSize, 0.9);
      if ((target - _sheetMax).abs() > 0.001) {
        setState(() => _sheetMax = target);
      }
    });
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

    // The shared tile factory owns the `TileLayer`; this screen only supplies
    // the app's tile config and renders whatever it returns (null in tests).
    final tileConfig = ref.watch(riderMapTileConfigProvider);
    final tile = ref.watch(mapTileLayerProvider(tileConfig));

    // Body-only: the shell (`RiderShell`, wired in `core/router/app_router.dart`)
    // owns the single `Scaffold` + drawer. Keeping no `Scaffold` here is what
    // makes the overlay toggle's `Scaffold.of(context)` open the shell drawer.
    return LayoutBuilder(
      builder: (context, constraints) {
        _availableHeight = constraints.maxHeight;
        return Stack(
          children: [
            // The map's layout box actually shrinks as the panel grows; it is
            // not merely covered by an overlay. `AnimatedBuilder` sizes a
            // wrapping `SizedBox` only, so the `FlutterMap` instance stays
            // stable (it is passed as `child`).
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedBuilder(
                animation: _sheetController,
                builder: (context, child) => SizedBox(
                  key: const ValueKey<String>('home-map'),
                  height: _mapHeight(_availableHeight),
                  width: double.infinity,
                  child: child,
                ),
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _currentPosition ?? _defaultMapCenter,
                    initialZoom: 15.0,
                  ),
                  children: [
            ?tile,
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
            MapTileAttribution(config: tileConfig),
          ],
        ),
      ),
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
            _buildBottomSheet(preview, _availableHeight),
            // The my-location control used to live on home's own `Scaffold`;
            // body-only means it moves into the map's overlay stack. It rides
            // above the panel's current height so even the collapsed panel
            // never covers it.
            Positioned(
              right: 16,
              bottom: 16,
              child: AnimatedBuilder(
                animation: _sheetController,
                builder: (context, child) => Transform.translate(
                  offset: Offset(0, -_panelPixels(_availableHeight)),
                  child: child,
                ),
                child: AppMapLocateButton(
                  routeKey: _homeRouteKey(preview),
                  hasRoute: _canFitRoute(preview),
                  onFitRoute: () => _fitRoute(preview),
                  onCurrentLocation: _locateCurrentPosition,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBottomSheet(HomeRoutePreview preview, double availableHeight) {
    final minSize = _minSheetSize(availableHeight);
    final maxSize = _sheetMax.clamp(_initialSize, 0.9);
    final initialSize = _initialSize.clamp(minSize, maxSize);
    return DraggableScrollableSheet(
      controller: _sheetController,
      snap: true,
      snapAnimationDuration: AppMotion.medium,
      initialChildSize: initialSize,
      minChildSize: minSize,
      maxChildSize: maxSize,
      // The sheet implies `min` and `max`; `initial` is the middle snap point.
      snapSizes: [initialSize],
      builder: (context, scrollController) {
        // The form is measured after layout; its intrinsic height sets the max
        // snap point so expanding always fits the whole booking form.
        _scheduleSheetMaxMeasure();
        return AppBottomSheet(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.lg),
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            padding: EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              key: _sheetContentKey,
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSheetHandle(),
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
        ),
        );
      },
    );
  }

  /// The panel's drag affordance: a 48 dp target with a `Semantics`
  /// min↔opening-size toggle. On desktop/web a mouse-only grabber drives
  /// [_sheetController] directly, superseding the 2026-10-08 "no second drag
  /// recognizer" lock there; the recognizer is mouse-only because the sheet's
  /// scrollable accepts trackpad drags, so the two never compete. On mobile the
  /// callbacks stay null and the list-scroll path remains the resize gesture.
  Widget _buildSheetHandle() {
    final canDrag = shouldEnableSheetDragHandle(
      isWeb: kIsWeb,
      platform: defaultTargetPlatform,
    );
    return AnimatedBuilder(
      animation: _sheetController,
      builder: (context, child) {
        final minSize = _minSheetSize(_availableHeight);
        final expanded = _panelSize > (minSize + _initialSize) / 2;
        return Semantics(
          label: 'Drag to resize booking panel',
          value: expanded ? 'Expanded' : 'Collapsed',
          button: true,
          onTap: _togglePanelSize,
          child: GestureDetector(
            key: const ValueKey<String>('home-sheet-handle'),
            behavior: HitTestBehavior.opaque,
            supportedDevices: const <PointerDeviceKind>{
              PointerDeviceKind.mouse,
            },
            onVerticalDragStart: canDrag ? _onSheetHandleDragStart : null,
            onVerticalDragUpdate: canDrag ? _onSheetHandleDragUpdate : null,
            onVerticalDragEnd: canDrag ? _onSheetHandleDragEnd : null,
            onVerticalDragCancel: canDrag ? _onSheetHandleDragCancel : null,
            child: const SizedBox(
              height: 48,
              child: Center(
                child: AppSheetHandle(
                  margin: EdgeInsets.only(bottom: AppSpacing.lg),
                ),
              ),
            ),
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
