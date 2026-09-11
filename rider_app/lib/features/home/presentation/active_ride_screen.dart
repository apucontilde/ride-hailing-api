import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import '../../../core/utils/location_helper.dart';
import '../data/ride_status_provider.dart';
import '../data/home_provider.dart';

class ActiveRideScreen extends ConsumerStatefulWidget {
  const ActiveRideScreen({super.key});

  @override
  ConsumerState<ActiveRideScreen> createState() => _ActiveRideScreenState();
}

class _ActiveRideScreenState extends ConsumerState<ActiveRideScreen> {
  final MapController _mapController = MapController();
  LatLng? _riderPosition;
  StreamSubscription<dynamic>? _positionSubscription;

  @override
  void initState() {
    super.initState();
    _initRiderLocation();
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
    _positionSubscription?.cancel();
    super.dispose();
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

  @override
  Widget build(BuildContext context) {
    final rideState = ref.watch(rideStatusProvider);
    final rideData = rideState.rideData;

    // Handle ride completion / cancellation
    ref.listen<RideState>(rideStatusProvider, (previous, next) {
      if (next.status == RideStatus.completed) {
        _showCompletionDialog();
      } else if (next.status == RideStatus.cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride cancelled successfully')),
        );
        context.go('/home');
      }
    });

    LatLng? driverPosition;
    if (rideData != null && rideData.containsKey('driver_lat') && rideData.containsKey('driver_lng')) {
      driverPosition = LatLng(
        rideData['driver_lat'] as double,
        rideData['driver_lng'] as double,
      );
    }

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
              if (_riderPosition != null && driverPosition != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [_riderPosition!, driverPosition],
                      color: Colors.blue,
                      strokeWidth: 4.0,
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
          _buildDriverInfoSheet(rideState, driverPosition),
        ],
      ),
    );
  }

  Widget _buildDriverInfoSheet(RideState rideState, LatLng? driverPosition) {
    final rideData = rideState.rideData;
    final driverName = rideData?['driver_name'] ?? 'Unknown Driver';
    final carModel = rideData?['car_model'] ?? 'Unknown Vehicle';
    final statusText = _getStatusText(rideState.status);

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
                const CircleAvatar(
                  radius: 30,
                  backgroundColor: Colors.grey,
                  child: Icon(Icons.person, color: Colors.white, size: 30),
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
                      Text(
                        carModel,
                        style: TextStyle(fontSize: 14, color: Colors.grey[600]),
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
            const SizedBox(height: 24),
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

  void _showCompletionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ride Completed!'),
          content: const Text('Thank you for riding with us.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                Future.delayed(const Duration(seconds: 2), () {
                  if (mounted) {
                    context.go('/home');
                  }
                });
              },
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }
}
