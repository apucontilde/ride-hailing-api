import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:latlong2/latlong.dart';
import '../providers/trip_notifier.dart';

/// Trip journey screen: stage-based primary button, route map with polyline,
/// and clean cancellation handling.
class TripScreen extends ConsumerStatefulWidget {
  const TripScreen({super.key});

  @override
  ConsumerState<TripScreen> createState() => _TripScreenState();
}

class _TripScreenState extends ConsumerState<TripScreen> {
  @override
  Widget build(BuildContext context) {
    final tripState = ref.watch(tripNotifierProvider);
    final ride = tripState.currentRide;
    final stage = tripState.stage;

    return Scaffold(
      appBar: AppBar(title: const Text('Trip')),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: ride != null
                ? _MapView(
                    pickupLat: ride.pickupLat ?? 0,
                    pickupLng: ride.pickupLng ?? 0,
                    dropoffLat: ride.dropoffLat ?? 0,
                    dropoffLng: ride.dropoffLng ?? 0,
                    polyline: tripState.route?.polyline,
                  )
                : const Center(child: Text('No active trip')),
          ),
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StageInfo(stage: stage, ride: ride),
                  const Spacer(),
                  if (stage == TripStage.cancelled)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'Trip cancelled',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    )
                  else ...[
                    if (stage == TripStage.pre)
                      FilledButton(
                        onPressed: () {
                          ref.read(tripNotifierProvider.notifier).advance();
                        },
                        child: const Text('Arrived at pickup'),
                      ),
                    if (stage == TripStage.enrouteToPickup)
                      FilledButton(
                        onPressed: () {
                          ref.read(tripNotifierProvider.notifier).advance();
                        },
                        child: const Text('Start trip'),
                      ),
                    if (stage == TripStage.driving)
                      FilledButton(
                        onPressed: () {
                          showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const Text('Complete trip?'),
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
                          ).then((ok) {
                            if (ok == true) {
                              ref.read(tripNotifierProvider.notifier).advance();
                            }
                          });
                        },
                        child: const Text('Complete Trip'),
                      ),
                    if (stage != TripStage.cancelled &&
                        stage != TripStage.post &&
                        stage != TripStage.driving)
                      OutlinedButton(
                        onPressed: () {
                          // Cancel only pre-in_progress.
                          if (stage == TripStage.pre ||
                            stage == TripStage.enrouteToPickup) {
                            // Call cancel logic.
                          }
                        },
                        child: const Text('Cancel'),
                      ),
                  ],
                  if (stage == TripStage.post && ride != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'Fare: \$${ride.totalFare?.toStringAsFixed(2) ?? '—'}',
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapView extends StatelessWidget {
  final double pickupLat;
  final double pickupLng;
  final double dropoffLat;
  final double dropoffLng;
  final List<Map<String, dynamic>>? polyline;

  const _MapView({
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
    this.polyline,
  });

  @override
  Widget build(BuildContext context) {
    final points = polyline
            ?.map((p) => LatLng(
                  (p['lat'] ?? 0.0) as double,
                  (p['lng'] ?? 0.0) as double,
                ))
            .toList() ??
        [
          LatLng(pickupLat, pickupLng),
          LatLng(dropoffLat, dropoffLng),
        ];

    return FlutterMap(
      options: MapOptions(
        initialCenter: LatLng(pickupLat, pickupLng),
        initialZoom: 13,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.driver.app',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: points,
              strokeWidth: 4,
              color: Colors.blue,
            ),
            if (polyline == null)
              Polyline(
                points: [
                  LatLng(pickupLat, pickupLng),
                  LatLng(dropoffLat, dropoffLng),
                ],
                strokeWidth: 2,
                color: Colors.grey,
              ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: LatLng(pickupLat, pickupLng),
              child: const Icon(Icons.location_pin, color: Colors.green),
            ),
            Marker(
              point: LatLng(dropoffLat, dropoffLng),
              child: const Icon(Icons.flag, color: Colors.red),
            ),
          ],
        ),
      ],
    );
  }
}

class _StageInfo extends StatelessWidget {
  final TripStage stage;
  final Ride? ride;

  const _StageInfo({required this.stage, this.ride});

  @override
  Widget build(BuildContext context) {
    final label = switch (stage) {
      TripStage.pre => 'En route to pickup',
      TripStage.enrouteToPickup => 'Arrived — start trip',
      TripStage.driving => 'Driving to dropoff',
      TripStage.post => 'Trip completed',
      TripStage.cancelled => 'Cancelled',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.headlineSmall),
        if (ride != null && stage == TripStage.post)
          Text('Total fare: \$${ride!.totalFare?.toStringAsFixed(2) ?? '—'}'),
      ],
    );
  }
}
