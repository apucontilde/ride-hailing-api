import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../navigation/rider_nav_items.dart';
import '../data/home_provider.dart';
import '../model/place.dart';
import 'ride_estimate_sheet.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final MapController _mapController = MapController();
  LatLng? _currentPosition;
  Place? _pickupLocation;
  Place? _destination;

  @override
  void initState() {
    super.initState();
    _initLocation();
  }

  void _fitBounds(LatLng pointA, LatLng pointB) {
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(pointA, pointB),
        padding: const EdgeInsets.all(60),
        maxZoom: 16.0,
      ),
    );
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
    final profile = ref.watch(riderProfileProvider);
    final email = ref.watch(authProvider).user?.email ?? '';
    // The rider's own name, falling back to their email. Seeded by the auth
    // bootstrap from `GET /rider/me`; empty only before the first fetch lands.
    final name = profile?.fullName.isNotEmpty == true ? profile!.fullName : email;

    final pickup = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;
    final routeArgs = (pickup != null && _destination != null)
        ? RouteArgs(
            fromLat: pickup.latitude,
            fromLng: pickup.longitude,
            toLat: _destination!.lat,
            toLng: _destination!.lng,
          )
        : null;
    final routeAsync = routeArgs != null ? ref.watch(navigationRouteProvider(routeArgs)) : null;

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: _initLocation,
        backgroundColor: Colors.white,
        child: const Icon(Icons.my_location, color: Colors.blue),
      ),
      drawer: AppSidebar(
        items: buildRiderNavItems(),
        // The rider shows no status dot and no rating, so `statusLabel` and
        // `ratingLabel` stay null and the header renders the email line.
        // `photoUrl` is passed raw: `RiderProfile` already normalises `'' → null`
        // and the shared header treats null and blank identically anyway.
        account: AppSidebarAccount(
          displayName: name,
          secondaryLine: email.isEmpty ? null : email,
          photoUrl: profile?.photoUrl,
        ),
        onAccountPressed: () {
          closeSidebar(context);
          context.push('/profile');
        },
        onItemSelected: (item) {
          closeSidebar(context);
          context.push(item.route);
        },
        footer: AppSidebarFooter(
          message: 'You will need to log in again to request rides.',
          onSignOut: () => ref.read(authProvider.notifier).logout(),
          onSignOutCompleted: () => context.go('/login'),
        ),
      ),
      body: Stack(
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
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36',
                  },
                ),
              ),
              if (_currentPosition != null || _pickupLocation != null || _destination != null)
                PolylineLayer(
                  polylines: [
                    if (routeAsync != null)
                      ...routeAsync.when(
                        data: (route) {
                          final straight = <LatLng>[
                            ?pickup,
                            LatLng(_destination!.lat, _destination!.lng),
                          ];
                          final useFallback =
                              route.polyline.length < 2 || route.isEstimate;
                          return [
                            if (straight.length == 2)
                              Polyline(
                                points: straight,
                                strokeWidth: 2,
                                color: Colors.grey,
                                pattern: StrokePattern.dashed(segments: const [12, 8]),
                              ),
                            if (!useFallback)
                              Polyline(
                                points: route.polyline,
                                strokeWidth: 4,
                                color: Colors.blue,
                              ),
                          ];
                        },
                        loading: () {
                          final straight = <LatLng>[
                            ?pickup,
                            LatLng(_destination!.lat, _destination!.lng),
                          ];
                          return [
                            if (straight.length == 2)
                              Polyline(
                                points: straight,
                                strokeWidth: 2,
                                color: Colors.grey,
                                pattern: StrokePattern.dashed(segments: const [12, 8]),
                              ),
                          ];
                        },
                        error: (_, _) {
                          final straight = <LatLng>[
                            ?pickup,
                            LatLng(_destination!.lat, _destination!.lng),
                          ];
                          return [
                            if (straight.length == 2)
                              Polyline(
                                points: straight,
                                strokeWidth: 2,
                                color: Colors.grey,
                                pattern: StrokePattern.dashed(segments: const [12, 8]),
                              ),
                          ];
                        },
                      ),
                  ],
                ),
              if (_currentPosition != null || _pickupLocation != null || _destination != null)
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
          _buildBottomSheet(routeAsync),
        ],
      ),
    );
  }

  Widget _buildBottomSheet(AsyncValue<NavigationRoute>? routeAsync) {
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
              _buildLocationField(
                icon: Icons.circle,
                iconColor: Colors.green,
                hint: 'Pickup location',
                value: _pickupLocation?.name ??
                    (_currentPosition != null ? 'Current location' : null),
                onTap: () async {
                  final origin = _pickupLocation != null
                      ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
                      : _currentPosition;
                  if (origin == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Could not determine your location')),
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
                    final pickup = LatLng(place.lat, place.lng);
                    if (_destination != null) {
                      _fitBounds(pickup, LatLng(_destination!.lat, _destination!.lng));
                    } else {
                      _mapController.move(pickup, 15.0);
                    }
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
                      const SnackBar(content: Text('Could not determine your location')),
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
                    final pickup = _pickupLocation != null
                        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
                        : _currentPosition;
                    if (pickup != null) {
                      _fitBounds(pickup, LatLng(place.lat, place.lng));
                    }
                  }
                },
              ),
              const SizedBox(height: 16),
              _buildRouteInfo(routeAsync),
              const SizedBox(height: 8),
              _buildRequestTripButton(),
            ],
          ),
        );
      },
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

  Widget _buildRouteInfo(AsyncValue<NavigationRoute>? routeAsync) {
    final route = routeAsync?.valueOrNull;

    // Error surface: only when there is no stale successful route.
    if (routeAsync != null && routeAsync.hasError && route == null) {
      return Row(
        children: [
          const Icon(Icons.error_outline, size: 16, color: Colors.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              apiErrorMessage(routeAsync.error!, 'Route unavailable'),
              style: const TextStyle(
                color: Colors.red,
                fontSize: 14,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              final pickup = _pickupLocation != null
                  ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
                  : _currentPosition;
              if (pickup != null && _destination != null) {
                final args = RouteArgs(
                  fromLat: pickup.latitude,
                  fromLng: pickup.longitude,
                  toLat: _destination!.lat,
                  toLng: _destination!.lng,
                );
                ref.invalidate(navigationRouteProvider(args));
              }
            },
            child: const Text('Retry'),
          ),
        ],
      );
    }

    if (route == null) return const SizedBox.shrink();

    final distanceKm = route.totalDistanceM / 1000;
    final minutes = (route.totalDurationS / 60).round();
    final prefix = route.isEstimate ? 'Estimated ' : '';

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

  Widget _buildRequestTripButton() {
    final rideState = ref.watch(rideCreationProvider);
    final canRequest =
        _destination != null && (_pickupLocation != null || _currentPosition != null);
    final isLoading = rideState.isLoading;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: canRequest && !isLoading ? () => _showRideEstimates(_destination!) : null,
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching estimates: $e')),
        );
      }
    }
  }

  Future<void> _createRide(Place destination, String vehicleType) async {
    final pickupPos = _pickupLocation != null
        ? LatLng(_pickupLocation!.lat, _pickupLocation!.lng)
        : _currentPosition;

    if (pickupPos == null) return;

    await ref.read(rideCreationProvider.notifier).createRide(
          pickupLat: pickupPos.latitude,
          pickupLng: pickupPos.longitude,
          pickupAddress: _pickupLocation?.address ?? 'Current Location',
          dropoffLat: destination.lat,
          dropoffLng: destination.lng,
          dropoffAddress: destination.address,
          vehicleType: vehicleType,
        );

    if (!mounted) return;
    final rideState = ref.read(rideCreationProvider);
    if (rideState.rideId != null) {
      context.go('/driver-matching');
    } else if (rideState.error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(rideState.error!)),
      );
    }
  }
}
