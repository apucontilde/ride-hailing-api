import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/home_provider.dart';

class NearbyDriversChip extends ConsumerWidget {
  final LatLng center;

  const NearbyDriversChip({super.key, required this.center});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final drivers = ref.watch(nearbyDriversProvider(center));
    final count = drivers.valueOrNull?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return AppStatusChip(
      icon: Icons.local_taxi,
      label: '$count ${count == 1 ? 'driver' : 'drivers'} nearby',
    );
  }
}
