import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';

class MockDriverWebSocketService extends Mock
    implements DriverWebSocketService {}

class MockApiClient extends Mock implements ApiClient {}

void main() {
  late MockDriverWebSocketService mockWs;
  late MockApiClient mockApiClient;
  late StreamController<WsEvent> events;
  late RideStateNotifier notifier;

  setUp(() {
    mockWs = MockDriverWebSocketService();
    mockApiClient = MockApiClient();
    events = StreamController<WsEvent>.broadcast();
    when(() => mockWs.events).thenAnswer((_) => events.stream);
    notifier = RideStateNotifier(mockWs, apiClient: mockApiClient);
    addTearDown(() async {
      await events.close();
      notifier.dispose();
    });
  });

  WsEvent offer(String rideId) =>
      WsEvent(type: WsEventType.offer, data: {'ride_id': rideId});

  WsEvent updated(Map<String, dynamic> rideJson) =>
      WsEvent(type: WsEventType.updated, data: rideJson);

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  test('offer records the offered ride id and deadline', () async {
    events.add(offer('r1'));
    await flush();

    expect(notifier.state.offeredRideId, 'r1');
    expect(notifier.state.offerExpiresAt, isNotNull);
  });

  test('offer without a ride id is ignored', () async {
    events.add(const WsEvent(type: WsEventType.offer, data: {}));
    await flush();

    expect(notifier.state.offeredRideId, isNull);
    expect(notifier.state.offerExpiresAt, isNull);
  });

  test('offer clears itself after the local deadline', () async {
    final notifier = RideStateNotifier(
      mockWs,
      apiClient: mockApiClient,
      offerTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(notifier.dispose);

    events.add(offer('r1'));
    await flush();
    expect(notifier.state.offeredRideId, 'r1');

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(notifier.state.offeredRideId, isNull);
    expect(notifier.state.offerExpiresAt, isNull);
  });

  test('ride.updated replaces the current ride and clears the offer', () async {
    events.add(offer('r1'));
    await flush();
    expect(notifier.state.offeredRideId, 'r1');

    events.add(updated({'id': 'r1', 'rider_id': 'u1', 'status': 'accepted'}));
    await flush();

    final ride = notifier.state.currentRide;
    expect(ride, isNotNull);
    expect(ride!.id, 'r1');
    expect(ride.status, 'accepted');
    expect(notifier.state.offeredRideId, isNull);
    expect(notifier.state.offerExpiresAt, isNull);
  });

  test('pending ride.updated keeps the outstanding offer', () async {
    events.add(offer('r1'));
    await flush();

    events.add(updated({'id': 'r1', 'rider_id': 'u1', 'status': 'pending'}));
    await flush();

    expect(notifier.state.offeredRideId, 'r1');
  });

  test('acceptOffer sends the accept and flips to an accepted placeholder',
      () async {
    events.add(offer('r1'));
    await flush();

    await notifier.acceptOffer();

    verify(() => mockWs.acceptOffer('r1')).called(1);
    expect(notifier.state.offeredRideId, isNull);
    expect(notifier.state.offerExpiresAt, isNull);
    final ride = notifier.state.currentRide;
    expect(ride, isNotNull);
    expect(ride!.id, 'r1');
    expect(ride.status, 'accepted');
  });

  test('acceptOffer is a no-op with no outstanding offer', () async {
    await notifier.acceptOffer();

    verifyNever(() => mockWs.acceptOffer(any()));
  });

  test('declineOffer sends the decline and clears the offer', () async {
    events.add(offer('r1'));
    await flush();

    notifier.declineOffer();

    verify(() => mockWs.declineOffer('r1')).called(1);
    expect(notifier.state.offeredRideId, isNull);
    expect(notifier.state.offerExpiresAt, isNull);
  });

  test('location event is a no-op', () async {
    events.add(updated({'id': 'r1', 'rider_id': 'u1', 'status': 'accepted'}));
    await flush();

    events.add(const WsEvent(
      type: WsEventType.location,
      data: {'lat': 9.93, 'lng': -84.08},
    ));
    await flush();

    expect(notifier.state.currentRide!.id, 'r1');
    expect(notifier.state.currentRide!.status, 'accepted');
  });

  test('second offer while one is open is ignored', () async {
    events.add(offer('r1'));
    await flush();

    events.add(offer('r2'));
    await flush();

    expect(notifier.state.offeredRideId, 'r1');
    verifyNever(() => mockWs.acceptOffer('r2'));
  });

  test('clearRide resets the current ride', () async {
    events.add(updated({'id': 'r1', 'rider_id': 'u1', 'status': 'in_progress'}));
    await flush();
    expect(notifier.state.currentRide, isNotNull);

    notifier.clearRide();

    expect(notifier.state.currentRide, isNull);
  });

  group('ride.updated in the real broadcast shape', () {
    // `internal/websocket.RideUpdateData` keys the ride `ride_id` and nests the
    // places and the fare, so parsing it as a flat `model.Ride` used to blank
    // the id and the coordinates the trip screen needs.
    const accepted = {
      'ride_id': 'r1',
      'status': 'accepted',
      'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
      'dropoff': {'lat': 9.95, 'lng': -84.1, 'address': 'Airport'},
    };

    test('reads the id and the nested places', () async {
      events.add(updated(accepted));
      await flush();

      final ride = notifier.state.currentRide!;
      expect(ride.id, 'r1');
      expect(ride.status, 'accepted');
      expect(ride.pickupLat, 9.93);
      expect(ride.pickupLng, -84.08);
      expect(ride.pickupAddress, 'Central Park');
      expect(ride.dropoffLat, 9.95);
      expect(ride.dropoffAddress, 'Airport');
    });

    test('a status-only event keeps the places already known', () async {
      events.add(updated(accepted));
      await flush();

      events.add(const WsEvent(
        type: WsEventType.updated,
        data: {'ride_id': 'r1', 'status': 'driver_arrived'},
      ));
      await flush();

      final ride = notifier.state.currentRide!;
      expect(ride.id, 'r1');
      expect(ride.status, 'driver_arrived');
      expect(ride.pickupLat, 9.93);
      expect(ride.dropoffLng, -84.1);
    });

    test('a completed event stores the nested fare', () async {
      events.add(updated(accepted));
      await flush();

      events.add(const WsEvent(
        type: WsEventType.updated,
        data: {
          'ride_id': 'r1',
          'status': 'completed',
          'fare': {
            'base_fare': 2.5,
            'distance_fare': 6.0,
            'time_fare': 3.3,
            'total': 13.2,
          },
        },
      ));
      await flush();

      final ride = notifier.state.currentRide!;
      expect(ride.status, 'completed');
      expect(ride.baseFare, 2.5);
      expect(ride.distanceFare, 6.0);
      expect(ride.timeFare, 3.3);
      expect(ride.totalFare, 13.2);
      expect(ride.pickupLat, 9.93);
    });

    test('a cancellation records who cancelled', () async {
      events.add(updated(accepted));
      await flush();

      events.add(const WsEvent(
        type: WsEventType.updated,
        data: {
          'ride_id': 'r1',
          'status': 'cancelled',
          'cancelled_by': 'rider',
        },
      ));
      await flush();

      expect(notifier.state.currentRide!.cancelledBy, 'rider');
    });

    test('a new ride replaces a terminal held ride', () async {
      events.add(updated({
        'ride_id': 'r1',
        'status': 'completed',
        'rider_id': 'u1',
      }));
      await flush();
      expect(notifier.state.currentRide!.status, 'completed');

      events.add(updated({
        'ride_id': 'r2',
        'status': 'accepted',
        'rider_id': 'u2',
      }));
      await flush();

      final ride = notifier.state.currentRide!;
      expect(ride.id, 'r2');
      expect(ride.status, 'accepted');
    });

    test('a different ride is ignored when held ride is non-terminal', () async {
      events.add(updated({
        'ride_id': 'r1',
        'status': 'in_progress',
        'rider_id': 'u1',
      }));
      await flush();

      events.add(updated({
        'ride_id': 'r2',
        'status': 'accepted',
        'rider_id': 'u2',
      }));
      await flush();

      final ride = notifier.state.currentRide!;
      expect(ride.id, 'r1');
      expect(ride.status, 'in_progress');
    });

    test('an event for a different ride is ignored', () async {
      events.add(updated(accepted));
      await flush();

      events.add(const WsEvent(
        type: WsEventType.updated,
        data: {'ride_id': 'r2', 'status': 'cancelled'},
      ));
      await flush();

      final ride = notifier.state.currentRide!;
      expect(ride.id, 'r1');
      expect(ride.status, 'accepted');
    });

    test('an event without an id or status is ignored', () async {
      events.add(updated(accepted));
      await flush();

      events.add(const WsEvent(
        type: WsEventType.updated,
        data: {'status': 'completed'},
      ));
      await flush();

      expect(notifier.state.currentRide!.status, 'accepted');
    });
  });

  test('adoptRide stores a ride learned over HTTP and clears the offer',
      () async {
    events.add(offer('r7'));
    await flush();

    notifier.adoptRide(const Ride(
      id: 'r7',
      riderId: 'u9',
      status: 'in_progress',
      pickupLat: 9.93,
      pickupLng: -84.08,
    ));

    expect(notifier.state.offeredRideId, isNull);
    expect(notifier.state.currentRide!.id, 'r7');
    expect(notifier.state.currentRide!.status, 'in_progress');
  });

  test('adoptRide ignores an id-less ride', () {
    notifier.adoptRide(const Ride(id: '', riderId: 'u', status: 'accepted'));

    expect(notifier.state.currentRide, isNull);
  });
}
