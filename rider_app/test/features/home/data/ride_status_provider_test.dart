import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';

class FakeWebSocketService extends WebSocketService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;

  void emit(Map<String, dynamic> event) => _controller.add(event);

  void disposeController() => _controller.close();
}

Map<String, dynamic> rideUpdated(Map<String, dynamic> data) =>
    {'type': 'ride.updated', 'data': data};

void main() {
  late FakeWebSocketService ws;
  late RideStatusNotifier notifier;

  setUp(() {
    ws = FakeWebSocketService();
    notifier = RideStatusNotifier(ws);
  });

  tearDown(() {
    notifier.dispose();
    ws.disposeController();
  });

  Future<void> emitAndSettle(Map<String, dynamic> event) async {
    ws.emit(event);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  Map<String, dynamic> acceptedData() => {
        'ride_id': 'ride-1',
        'status': 'accepted',
        'timestamp': '2026-09-10T00:00:00Z',
        'eta_seconds': 300,
        'driver': {
          'id': 'driver-1',
          'first_name': 'Maria',
          'photo_url': 'https://example.com/maria.jpg',
          'rating': 4.9,
          'vehicle': {
            'make': 'Toyota',
            'model': 'Corolla',
            'color': 'White',
            'plate_number': 'AB123CD',
          },
          'location': {'lat': 9.93, 'lng': -84.09, 'heading': 90},
        },
        'pickup': {'lat': 9.9281, 'lng': -84.0907, 'address': 'Main St'},
        'dropoff': {'lat': 9.94, 'lng': -84.10, 'address': 'Airport Rd'},
      };

  group('RideStatusNotifier', () {
    test('initial state is idle', () {
      expect(notifier.state.status, RideStatus.idle);
      expect(notifier.state.rideId, isNull);
      expect(notifier.state.driver, isNull);
      expect(notifier.state.driverLocation, isNull);
      expect(notifier.state.fare, isNull);
      expect(notifier.state.cancelledBy, isNull);
    });

    test('maps ride.updated pending to matching with rideId', () async {
      await emitAndSettle(rideUpdated({'ride_id': 'ride-2', 'status': 'pending'}));

      expect(notifier.state.status, RideStatus.matching);
      expect(notifier.state.rideId, 'ride-2');
      expect(notifier.state.driver, isNull);
    });

    test('maps ride.updated accepted to driverApproaching and parses driver', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      expect(notifier.state.status, RideStatus.driverApproaching);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.etaSeconds, 300);

      final driver = notifier.state.driver;
      expect(driver, isNotNull);
      expect(driver!.id, 'driver-1');
      expect(driver.firstName, 'Maria');
      expect(driver.photoUrl, 'https://example.com/maria.jpg');
      expect(driver.rating, 4.9);
      expect(driver.vehicle?.make, 'Toyota');
      expect(driver.vehicle?.model, 'Corolla');
      expect(driver.vehicle?.color, 'White');
      expect(driver.vehicle?.plateNumber, 'AB123CD');
      expect(driver.location?.lat, 9.93);
      expect(driver.location?.lng, -84.09);
      expect(driver.location?.heading, 90);
    });

    test('maps ride.updated driver_arrived to driverArrived', () async {
      await emitAndSettle(rideUpdated(acceptedData()));
      await emitAndSettle(rideUpdated({'ride_id': 'ride-1', 'status': 'driver_arrived'}));

      expect(notifier.state.status, RideStatus.driverArrived);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver?.id, 'driver-1');
    });

    test('maps ride.updated in_progress to onTrip', () async {
      await emitAndSettle(rideUpdated(acceptedData()));
      await emitAndSettle(rideUpdated({'ride_id': 'ride-1', 'status': 'in_progress'}));

      expect(notifier.state.status, RideStatus.onTrip);
      expect(notifier.state.driver?.id, 'driver-1');
    });

    test('maps ride.updated completed to completed and parses fare', () async {
      await emitAndSettle(rideUpdated(acceptedData()));
      await emitAndSettle(rideUpdated({
        'ride_id': 'ride-1',
        'status': 'completed',
        'fare': {
          'base_fare': 1.5,
          'distance_fare': 5.0,
          'time_fare': 2.0,
          'surge_multiplier': 1.0,
          'total': 8.5,
        },
      }));

      expect(notifier.state.status, RideStatus.completed);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver?.id, 'driver-1');

      final fare = notifier.state.fare;
      expect(fare, isNotNull);
      expect(fare!.baseFare, 1.5);
      expect(fare.distanceFare, 5.0);
      expect(fare.timeFare, 2.0);
      expect(fare.surgeMultiplier, 1.0);
      expect(fare.total, 8.5);
    });

    test('maps ride.updated cancelled to cancelled and keeps cancelled_by', () async {
      await emitAndSettle(rideUpdated(acceptedData()));
      await emitAndSettle(rideUpdated({'ride_id': 'ride-1', 'status': 'cancelled', 'cancelled_by': 'rider'}));

      expect(notifier.state.status, RideStatus.cancelled);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.cancelledBy, 'rider');
    });

    test('maps ride.updated no_driver_available to noDriverAvailable', () async {
      await emitAndSettle(rideUpdated({
        'ride_id': 'ride-1',
        'status': 'no_driver_available',
        'timestamp': '2026-09-10T00:00:00Z',
      }));

      expect(notifier.state.status, RideStatus.noDriverAvailable);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver, isNull);
    });

    test('driver.location updates driverLocation without changing status', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      await emitAndSettle({
        'type': 'driver.location',
        'data': {
          'ride_id': 'ride-1',
          'driver_id': 'driver-1',
          'lat': 9.931,
          'lng': -84.091,
          'heading': 100,
          'speed': 12.5,
        },
      });

      expect(notifier.state.status, RideStatus.driverApproaching);
      expect(notifier.state.rideId, 'ride-1');

      final location = notifier.state.driverLocation;
      expect(location, isNotNull);
      expect(location!.driverId, 'driver-1');
      expect(location.lat, 9.931);
      expect(location.lng, -84.091);
      expect(location.heading, 100);
      expect(location.speed, 12.5);
    });

    test('ignores ride_matched', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      await emitAndSettle({'type': 'ride_matched', 'data': {'ride_id': 'ignored'}});

      expect(notifier.state.status, RideStatus.driverApproaching);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver?.id, 'driver-1');
      expect(notifier.state.driverLocation, isNull);
    });

    test('ignores driver_moved', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      await emitAndSettle({'type': 'driver_moved', 'data': {'ride_id': 'ignored'}});

      expect(notifier.state.status, RideStatus.driverApproaching);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver?.id, 'driver-1');
      expect(notifier.state.driverLocation, isNull);
    });

    test('ignores ride_arrived', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      await emitAndSettle({'type': 'ride_arrived', 'data': {'ride_id': 'ignored'}});

      expect(notifier.state.status, RideStatus.driverApproaching);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver?.id, 'driver-1');
    });

    test('ignores ride_completed', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      await emitAndSettle({'type': 'ride_completed', 'data': {'ride_id': 'ignored'}});

      expect(notifier.state.status, RideStatus.driverApproaching);
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.driver?.id, 'driver-1');
    });

    test('a new pending ride clears previous session fields', () async {
      await emitAndSettle(rideUpdated(acceptedData()));
      await emitAndSettle(rideUpdated({
        'ride_id': 'ride-2',
        'status': 'completed',
        'fare': {'total': 8.5},
      }));

      await emitAndSettle(rideUpdated({'ride_id': 'ride-3', 'status': 'pending'}));

      expect(notifier.state.status, RideStatus.matching);
      expect(notifier.state.rideId, 'ride-3');
      expect(notifier.state.driver, isNull);
      expect(notifier.state.driverLocation, isNull);
      expect(notifier.state.fare, isNull);
      expect(notifier.state.cancelledBy, isNull);
    });

    test('reset returns to idle state', () async {
      await emitAndSettle(rideUpdated(acceptedData()));

      notifier.reset();

      expect(notifier.state.status, RideStatus.idle);
      expect(notifier.state.rideId, isNull);
      expect(notifier.state.driver, isNull);
    });
  });
}