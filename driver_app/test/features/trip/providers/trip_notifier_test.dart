import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/features/trip/providers/trip_notifier.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockDriverWebSocketService extends Mock
    implements DriverWebSocketService {}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late RideStateNotifier rideState;
  late ProviderContainer container;
  late TripNotifier notifier;

  // 0.001° of latitude is ~111 m, 0.003° is ~333 m — either side of the
  // 200 m refetch threshold.
  const pickupLat = 9.9300, pickupLng = -84.0800;
  const dropoffLat = 9.9500, dropoffLng = -84.1000;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    final mockWs = MockDriverWebSocketService();
    when(() => mockWs.events)
        .thenAnswer((_) => const Stream<WsEvent>.empty());
    rideState = RideStateNotifier(mockWs, apiClient: MockApiClient());

    // The container owns the overridden provider, so it disposes the
    // notifier — no separate teardown here.
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
      ],
    );
    addTearDown(container.dispose);
    notifier = container.read(tripNotifierProvider.notifier);
  });

  Response jsonResponse(Map<String, dynamic> data) => Response(
        requestOptions: RequestOptions(path: '/stub'),
        statusCode: 200,
        data: data,
      );

  /// Pushes a `ride.updated` broadcast in the real wire shape.
  void broadcast({
    String rideId = 'r1',
    String status = 'accepted',
    Map<String, dynamic>? fare,
    String? cancelledBy,
  }) {
    rideState.onWsEvent(WsEvent(
      type: WsEventType.updated,
      data: {
        'ride_id': rideId,
        'status': status,
        'fare': ?fare,
        'cancelled_by': ?cancelledBy,
      },
    ));
  }

  /// A full `accepted` broadcast, i.e. what the dispatch/accept path delivers.
  void seedAcceptedRide() {
    broadcast(status: 'accepted');
    rideState.onWsEvent(WsEvent(
      type: WsEventType.updated,
      data: {
        'ride_id': 'r1',
        'status': 'accepted',
        'pickup': {
          'lat': pickupLat,
          'lng': pickupLng,
          'address': 'Central Park',
        },
        'dropoff': {
          'lat': dropoffLat,
          'lng': dropoffLng,
          'address': 'Airport',
        },
      },
    ));
  }

  void stubStatusPut({String status = 'driver_arrived'}) {
    when(() => mockDio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => jsonResponse({
        'ride': {
          'id': 'r1',
          'rider_id': 'u1',
          'status': status,
          'pickup_lat': pickupLat,
          'pickup_lng': pickupLng,
          'dropoff_lat': dropoffLat,
          'dropoff_lng': dropoffLng,
        },
      }),
    );
  }

  void stubRouteGet({bool estimate = false, int points = 3}) {
    when(() => mockDio.get(
      ApiEndpoints.navigationRoute,
      queryParameters: any(named: 'queryParameters'),
    )).thenAnswer((_) async => jsonResponse({
          'polyline': List.generate(
            points,
            (i) => {
              'lat': pickupLat + i * 0.001,
              'lng': pickupLng,
            },
          ),
          'total_distance_m': 4200,
          'total_duration_s': 380,
          if (estimate) 'is_estimate': true,
        }));
  }

  group('stage mapping mirrors the server state machine', () {
    test('accepted maps to enrouteToPickup', () {
      seedAcceptedRide();
      expect(notifier.state.stage, TripStage.enrouteToPickup);
    });

    test('driver_arrived maps to its own arrived stage', () {
      seedAcceptedRide();
      broadcast(status: 'driver_arrived');

      // The pre-audit code collapsed accepted+driver_arrived into one stage,
      // which made the first button press send an illegal `in_progress`.
      expect(notifier.state.stage, TripStage.arrived);
    });

    test('in_progress maps to driving', () {
      seedAcceptedRide();
      broadcast(status: 'in_progress');
      expect(notifier.state.stage, TripStage.driving);
    });

    test('completed maps to post and cancelled maps to cancelled', () {
      seedAcceptedRide();
      broadcast(status: 'completed');
      expect(notifier.state.stage, TripStage.post);

      broadcast(status: 'cancelled');
      expect(notifier.state.stage, TripStage.cancelled);
    });

    test('a status-only broadcast keeps the held ride id and places', () {
      seedAcceptedRide();
      broadcast(status: 'driver_arrived');

      final ride = notifier.state.currentRide;
      expect(ride, isNotNull);
      expect(ride!.id, 'r1');
      expect(ride.pickupLat, pickupLat);
      expect(ride.dropoffLng, dropoffLng);
    });

    test('a broadcast for another ride does not replace the held one', () {
      seedAcceptedRide();
      broadcast(rideId: 'other', status: 'in_progress');

      expect(notifier.state.currentRide!.id, 'r1');
    });

    test('cancelled_by from the event is surfaced', () {
      seedAcceptedRide();
      broadcast(status: 'cancelled', cancelledBy: 'rider');

      expect(notifier.state.stage, TripStage.cancelled);
      expect(notifier.state.cancelledBy, 'rider');
    });
  });

  group('advance()', () {
    test('enrouteToPickup puts driver_arrived and adopts the response',
        () async {
      seedAcceptedRide();
      stubStatusPut();

      await notifier.advance();

      final captured = verify(
        () => mockDio.put(ApiEndpoints.driverRideStatus('r1'),
            data: captureAny(named: 'data')),
      ).captured;
      expect((captured.first as Map)['status'], 'driver_arrived');
      expect(notifier.state.stage, TripStage.arrived);
    });

    test('arrived puts in_progress', () async {
      seedAcceptedRide();
      broadcast(status: 'driver_arrived');
      stubStatusPut(status: 'in_progress');

      await notifier.advance();

      final captured = verify(
        () => mockDio.put(ApiEndpoints.driverRideStatus('r1'),
            data: captureAny(named: 'data')),
      ).captured;
      expect((captured.first as Map)['status'], 'in_progress');
      expect(notifier.state.stage, TripStage.driving);
    });

    test('driving puts completed and keeps the fare the server returned',
        () async {
      seedAcceptedRide();
      broadcast(status: 'in_progress');
      when(() => mockDio.put(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => jsonResponse({
          'ride': {
            'id': 'r1',
            'status': 'completed',
            'pickup_lat': pickupLat,
            'dropoff_lat': dropoffLat,
            'total_fare': 13.2,
          },
        }),
      );

      await notifier.advance();

      final captured = verify(
        () => mockDio.put(ApiEndpoints.driverRideStatus('r1'),
            data: captureAny(named: 'data')),
      ).captured;
      expect((captured.first as Map)['status'], 'completed');
      expect(notifier.state.stage, TripStage.post);
      expect(notifier.state.currentRide!.totalFare, 13.2);
    });

    test('completion adopts the final total over the held booked quote',
        () async {
      seedAcceptedRide();
      // The booked quote the driver already holds.
      broadcast(status: 'in_progress', fare: {'total': 10.0});
      expect(notifier.state.currentRide!.totalFare, 10.0);
      when(() => mockDio.put(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => jsonResponse({
          'ride': {'id': 'r1', 'status': 'completed', 'total_fare': 13.2},
        }),
      );

      await notifier.advance();

      expect(notifier.state.currentRide!.totalFare, 13.2);
    });

    test('a completion broadcast replaces the booked total with the final', () {
      seedAcceptedRide();
      broadcast(status: 'in_progress', fare: {'total': 10.0});
      expect(notifier.state.currentRide!.totalFare, 10.0);

      broadcast(status: 'completed', fare: {'total': 13.2});

      expect(notifier.state.stage, TripStage.post);
      expect(notifier.state.currentRide!.totalFare, 13.2);
    });

    test('an illegal transition is refused before the network', () async {
      seedAcceptedRide();
      broadcast(status: 'completed');

      await notifier.advance();

      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
    });

    test('a cancelled trip cannot be advanced', () async {
      seedAcceptedRide();
      broadcast(status: 'cancelled');

      await notifier.advance();

      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
    });

    test('a pending ride has no driver transition', () async {
      broadcast(status: 'pending');

      await notifier.advance();

      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
    });

    test('with no ride held nothing is sent', () async {
      await notifier.advance();

      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
    });

    test('a rejected transition leaves the stage untouched', () async {
      seedAcceptedRide();
      when(() => mockDio.put(any(), data: any(named: 'data')))
          .thenThrow(DioException(requestOptions: RequestOptions(path: '/')));

      await notifier.advance();

      expect(notifier.state.stage, TripStage.enrouteToPickup);
    });
  });

  group('cancelTrip()', () {
    test('posts the cancel endpoint and lands on cancelled', () async {
      seedAcceptedRide();
      when(() => mockDio.post(any(), data: any(named: 'data'))).thenAnswer(
        (_) async => jsonResponse({
          'ride': {
            'id': 'r1',
            'status': 'cancelled',
            'cancelled_by': 'driver',
            'pickup_lat': pickupLat,
          },
        }),
      );

      await notifier.cancelTrip(reason: 'rider not showing up');

      verify(() => mockDio.post(
            ApiEndpoints.driverRideCancel('r1'),
            data: {'reason': 'rider not showing up'},
          )).called(1);
      expect(notifier.state.stage, TripStage.cancelled);
    });

    test('is refused once the trip is in progress', () async {
      seedAcceptedRide();
      broadcast(status: 'in_progress');

      await notifier.cancelTrip();

      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
      expect(notifier.state.canCancel, isFalse);
    });

    test('is refused after completion', () async {
      seedAcceptedRide();
      broadcast(status: 'completed');

      await notifier.cancelTrip();

      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
    });

    test('is refused with no ride held', () async {
      await notifier.cancelTrip();

      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));
    });
  });

  group('fetchRoute()', () {
    test('requests the road route and publishes it on state', () async {
      stubRouteGet();

      final route = await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      expect(route, isNotNull);
      expect(route!.polyline.length, 3);
      expect(route.distance, 4200);
      expect(route.duration, 380);
      expect(route.isEstimate, isFalse);
      expect(notifier.state.route, route);
    });

    test('sends the four mandatory query params', () async {
      stubRouteGet();
      when(() => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      )).thenAnswer((invocation) async {
        final params =
            invocation.namedArguments[#queryParameters] as Map<String, dynamic>;
        expect(params.keys.toSet(),
            {'from_lat', 'from_lng', 'to_lat', 'to_lng'});
        return jsonResponse({
          'polyline': [
            {'lat': 1.0, 'lng': 2.0},
          ],
          'total_distance_m': 1,
          'total_duration_s': 1,
        });
      });

      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
    });

    test('reuses the cache while the driver is within 200 m', () async {
      stubRouteGet();

      final first = await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      // ~111 m north: still the same origin.
      final second = await notifier.fetchRoute(
        fromLat: pickupLat + 0.001,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat + 0.001,
        currentLng: pickupLng,
      );

      expect(second, same(first));
      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(1);
    });

    test('refetches once the driver has moved more than 200 m', () async {
      stubRouteGet();

      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      // ~333 m north: the cached origin is stale.
      await notifier.fetchRoute(
        fromLat: pickupLat + 0.003,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat + 0.003,
        currentLng: pickupLng,
      );

      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(2);
    });

    test('refetches when the destination changes', () async {
      stubRouteGet();

      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat + 0.01,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(2);
    });

    test('collapses concurrent calls onto one request', () async {
      stubRouteGet();

      await Future.wait([
        notifier.fetchRoute(
          fromLat: pickupLat,
          fromLng: pickupLng,
          toLat: dropoffLat,
          toLng: dropoffLng,
          currentLat: pickupLat,
          currentLng: pickupLng,
        ),
        notifier.fetchRoute(
          fromLat: pickupLat + 0.005,
          fromLng: pickupLng,
          toLat: dropoffLat,
          toLng: dropoffLng,
          currentLat: pickupLat + 0.005,
          currentLng: pickupLng,
        ),
      ]);

      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(1);
    });

    test('flags an out-of-coverage estimate', () async {
      stubRouteGet(estimate: true, points: 2);

      final route = await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      expect(route!.isEstimate, isTrue);
    });

    test('returns null on failure so the screen draws the fallback',
        () async {
      when(() => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      )).thenThrow(DioException(requestOptions: RequestOptions(path: '/')));

      final route = await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      expect(route, isNull);
      expect(notifier.state.route, isNull);
      expect(notifier.state.routeError, isNotNull);
      expect(notifier.state.routeError, contains('Route unavailable'));
    });

    test('success clears a previous route error', () async {
      when(() => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      )).thenThrow(DioException(requestOptions: RequestOptions(path: '/')));
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      expect(notifier.state.routeError, isNotNull);

      stubRouteGet();
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      expect(notifier.state.routeError, isNull);
      expect(notifier.state.route, isNotNull);
    });

    test('tolerates integer coordinates in the polyline', () async {
      when(() => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      )).thenAnswer((_) async => jsonResponse({
            'polyline': [
              {'lat': 9, 'lng': -84},
            ],
            'total_distance_m': 10,
            'total_duration_s': 5,
          }));

      final route = await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      expect(route!.polyline.first['lat'], 9.0);
    });
  });

  group('reset()', () {
    test('clears the ride, the route and the cache', () async {
      seedAcceptedRide();
      stubRouteGet();
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      expect(notifier.state.route, isNotNull);

      notifier.reset();

      expect(notifier.state.route, isNull);
      expect(notifier.state.currentRide, isNull);
      expect(notifier.state.stage, TripStage.pre);

      // The cache went with it: the same leg is fetched again.
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );
      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(2);
    });

    test('a new ride drops the previous route cache', () async {
      seedAcceptedRide();
      stubRouteGet();
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      broadcast(rideId: 'r2', status: 'accepted');
      await notifier.fetchRoute(
        fromLat: pickupLat,
        fromLng: pickupLng,
        toLat: dropoffLat,
        toLng: dropoffLng,
        currentLat: pickupLat,
        currentLng: pickupLng,
      );

      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(1);
    });
  });
}
