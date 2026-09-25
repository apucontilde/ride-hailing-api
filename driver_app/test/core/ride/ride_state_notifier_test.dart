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

  test('driver.location is stored for the trip map', () async {
    events.add(const WsEvent(
      type: WsEventType.location,
      data: {'lat': 9.93, 'lng': -84.08},
    ));
    await flush();

    expect(notifier.state.lastLocation, {'lat': 9.93, 'lng': -84.08});
  });

  test('second offer while one is open is ignored', () async {
    events.add(offer('r1'));
    await flush();

    events.add(offer('r2'));
    await flush();

    expect(notifier.state.offeredRideId, 'r1');
    verifyNever(() => mockWs.acceptOffer('r2'));
  });

  test('clearRide resets the current ride and location', () async {
    events.add(updated({'id': 'r1', 'rider_id': 'u1', 'status': 'in_progress'}));
    await flush();
    events.add(const WsEvent(
      type: WsEventType.location,
      data: {'lat': 9.93, 'lng': -84.08},
    ));
    await flush();
    expect(notifier.state.currentRide, isNotNull);

    notifier.clearRide();

    expect(notifier.state.currentRide, isNull);
    expect(notifier.state.lastLocation, isNull);
  });
}
