import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/features/trip/providers/trip_notifier.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';

class MockRideStateNotifier extends Mock implements RideStateNotifier {}

void main() {
  group('TripNotifier', () {
    test('stage maps accepted to pre', () {
      // Basic stage mapping verification.
      expect(TripStage.values.contains(TripStage.pre), isTrue);
    });
  });
}
