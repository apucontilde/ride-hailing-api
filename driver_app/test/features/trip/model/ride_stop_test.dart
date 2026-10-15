import 'package:flutter_test/flutter_test.dart';
import 'package:driver_app/features/trip/model/ride_stop.dart';

void main() {
  group('RideStop', () {
    test('parses the wire shape', () {
      final stop = RideStop.fromJson({
        'sequence': 2,
        'kind': 'stop',
        'lat': 9.93,
        'lng': -84.08,
        'address': 'Midpoint Cafe',
      });

      expect(stop.sequence, 2);
      expect(stop.kind, 'stop');
      expect(stop.lat, 9.93);
      expect(stop.lng, -84.08);
      expect(stop.address, 'Midpoint Cafe');
      expect(stop.isDestination, isFalse);
    });

    test('flags the destination row', () {
      final stop = RideStop.fromJson({
        'sequence': 3,
        'kind': 'destination',
        'lat': 9.95,
        'lng': -84.1,
      });

      expect(stop.isDestination, isTrue);
      expect(stop.address, '');
    });

    test('tolerates missing/nullable fields', () {
      final stop = RideStop.fromJson(const {});

      expect(stop.sequence, 0);
      expect(stop.kind, 'stop');
      expect(stop.lat, 0);
      expect(stop.lng, 0);
      expect(stop.isDestination, isFalse);
    });
  });
}
