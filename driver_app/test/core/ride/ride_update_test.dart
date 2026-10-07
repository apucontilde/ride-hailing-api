import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/ride/ride_update.dart';

/// The booked ride the driver already holds when a completion event lands.
Ride booked({double? totalFare = 10.0}) => Ride(
      id: 'r1',
      riderId: 'u1',
      status: 'in_progress',
      totalFare: totalFare,
    );

void main() {
  group('RideUpdate completion fare', () {
    test('fromJson reads the final total from the nested fare object', () {
      final update = RideUpdate.fromJson({
        'ride_id': 'r1',
        'status': 'completed',
        'fare': {
          'base_fare': 2.5,
          'distance_fare': 6.0,
          'time_fare': 3.3,
          'total': 13.2,
        },
      });

      expect(update.totalFare, 13.2);
      expect(update.baseFare, 2.5);
      expect(update.distanceFare, 6.0);
    });

    test('applyTo replaces the booked total with the completion final', () {
      final update = RideUpdate.fromJson({
        'ride_id': 'r1',
        'status': 'completed',
        'fare': {'total': 13.2},
      });

      expect(update.applyTo(booked()).totalFare, 13.2);
    });

    test('applyTo keeps the held total when the event carries no fare', () {
      final update = RideUpdate.fromJson({
        'ride_id': 'r1',
        'status': 'driver_arrived',
      });

      expect(update.applyTo(booked()).totalFare, 10.0);
    });

    test('applyTo never fabricates a fare that was never sent', () {
      final update = RideUpdate.fromJson({
        'ride_id': 'r1',
        'status': 'completed',
      });

      expect(update.applyTo(booked(totalFare: null)).totalFare, isNull);
    });
  });
}
