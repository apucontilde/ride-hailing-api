import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/location/location_service.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/features/rides/presentation/rate_sheet.dart';
import 'package:driver_app/features/trip/presentation/trip_screen.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockDriverWebSocketService extends Mock
    implements DriverWebSocketService {}

void main() {
  const pickupLat = 9.9300, pickupLng = -84.0800;
  const dropoffLat = 9.9500, dropoffLng = -84.1000;

  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late RideStateNotifier rideState;
  late ProviderContainer container;

  Response jsonResponse(Map<String, dynamic> data) => Response(
        requestOptions: RequestOptions(path: '/stub'),
        statusCode: 200,
        data: data,
      );

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    final mockWs = MockDriverWebSocketService();
    when(() => mockWs.events)
        .thenAnswer((_) => const Stream<WsEvent>.empty());
    rideState = RideStateNotifier(mockWs, apiClient: MockApiClient());

    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        // No tiles: the map must not touch the network under flutter_test.
        tripMapTileProvider.overrideWith((ref) => null),
        lastPositionProvider
            .overrideWith((ref) => const GeoPoint(pickupLat, pickupLng)),
      ],
    );
    addTearDown(container.dispose);
  });

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
        'pickup': {'lat': pickupLat, 'lng': pickupLng, 'address': 'Central Park'},
        'dropoff': {'lat': dropoffLat, 'lng': dropoffLng, 'address': 'Airport'},
      },
    ));
  }

  void stubPut(String status) {
    when(() => mockDio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => jsonResponse({
        'ride': {
          'id': 'r1',
          'status': status,
          'pickup_lat': pickupLat,
          'dropoff_lat': dropoffLat,
          'total_fare': 13.2,
        },
      }),
    );
  }

  void stubPost() {
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
  }

  void stubRouteGet() {
    when(() => mockDio.get(
      ApiEndpoints.navigationRoute,
      queryParameters: any(named: 'queryParameters'),
    )).thenAnswer((_) async => jsonResponse({
          'polyline': [
            {'lat': pickupLat, 'lng': pickupLng},
            {'lat': pickupLat + 0.01, 'lng': pickupLng + 0.01},
            {'lat': dropoffLat, 'lng': dropoffLng},
          ],
          'total_distance_m': 4200,
          'total_duration_s': 380,
        }));
  }

  Future<void> pumpTrip(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/trip',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('home screen')),
        ),
        GoRoute(path: '/trip', builder: (_, _) => const TripScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
  }

  List<Polyline> polylines(WidgetTester tester) =>
      tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines;

  group('without a held ride', () {
    testWidgets('shows no active trip', (tester) async {
      await pumpTrip(tester);

      expect(find.text('No active trip'), findsOneWidget);
      expect(find.byKey(const Key('trip-primary-button')), findsNothing);
    });
  });

  group('stage buttons', () {
    testWidgets('a ride held before the screen opens is picked up',
        (tester) async {
      // The home screen pushes /trip *because* a ride is already held, and the
      // launch restore adopts one before the first frame.
      broadcast(status: 'in_progress');
      await pumpTrip(tester);

      expect(find.text('Driving to the dropoff'), findsOneWidget);
      expect(find.text('Complete Trip'), findsOneWidget);
    });

    testWidgets('enrouteToPickup offers arrival and advances to arrived',
        (tester) async {
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      stubPut('driver_arrived');

      expect(find.text('Drive to the pickup'), findsOneWidget);
      expect(find.text('Central Park'), findsOneWidget);
      expect(find.text('Arrived at pickup'), findsOneWidget);

      await tester.tap(find.byKey(const Key('trip-primary-button')));
      await tester.pump();
      await tester.pump();

      final captured = verify(
        () => mockDio.put(ApiEndpoints.driverRideStatus('r1'),
            data: captureAny(named: 'data')),
      ).captured;
      expect((captured.first as Map)['status'], 'driver_arrived');
      expect(find.text('Arrived at the pickup'), findsOneWidget);
      expect(find.text('Start trip'), findsOneWidget);
    });

    testWidgets('arrived starts the trip and then shows the complete button',
        (tester) async {
      await pumpTrip(tester);
      broadcast(status: 'driver_arrived');
      await tester.pump();
      stubPut('in_progress');

      expect(find.text('Start trip'), findsOneWidget);
      await tester.tap(find.byKey(const Key('trip-primary-button')));
      await tester.pump();
      await tester.pump();

      final captured = verify(
        () => mockDio.put(ApiEndpoints.driverRideStatus('r1'),
            data: captureAny(named: 'data')),
      ).captured;
      expect((captured.first as Map)['status'], 'in_progress');
      expect(find.text('Driving to the dropoff'), findsOneWidget);
      expect(find.text('Complete Trip'), findsOneWidget);
      // In progress the driver can no longer cancel.
      expect(find.byKey(const Key('trip-cancel-button')), findsNothing);
      expect(find.text('Rider can cancel from here'), findsOneWidget);
    });

    testWidgets('driving asks for confirmation before completing',
        (tester) async {
      await pumpTrip(tester);
      broadcast(status: 'in_progress');
      await tester.pump();
      stubPut('completed');

      await tester.tap(find.byKey(const Key('trip-primary-button')));
      await tester.pumpAndSettle();
      expect(find.text('Complete trip?'), findsOneWidget);

      // Backing out of the dialog must not complete anything.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));

      await tester.tap(find.byKey(const Key('trip-primary-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump();

      final captured = verify(
        () => mockDio.put(ApiEndpoints.driverRideStatus('r1'),
            data: captureAny(named: 'data')),
      ).captured;
      expect((captured.first as Map)['status'], 'completed');
      expect(find.text('Trip completed'), findsOneWidget);
    });

    testWidgets('a completed trip shows the fare and returns home',
        (tester) async {
      await pumpTrip(tester);
      broadcast(
        status: 'completed',
        fare: {
          'base_fare': 2.5,
          'distance_fare': 6.0,
          'time_fare': 3.3,
          'total': 11.8,
        },
      );
      await tester.pump();

      expect(find.text('\$11.80'), findsOneWidget);
      expect(find.text('\$2.50'), findsOneWidget);

      await tester.tap(find.byKey(const Key('trip-done-button')));
      await tester.pumpAndSettle();

      expect(find.text('home screen'), findsOneWidget);
      expect(rideState.state.currentRide, isNull);
    });
  });

  group('rating after the trip', () {
    void completeTrip() {
      broadcast(
        status: 'completed',
        fare: {'base_fare': 2.5, 'total': 11.8},
      );
    }

    testWidgets('the post screen offers to rate the rider', (tester) async {
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsOneWidget);
      expect(find.text('Rate the rider'), findsOneWidget);
    });

    testWidgets('tapping it opens the sheet for the completed ride',
        (tester) async {
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();

      await tester.tap(find.byKey(const Key('trip-rate-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.byType(RateSheet), findsOneWidget);
      expect(find.text('Rate your rider'), findsOneWidget);
    });

    testWidgets('the prompt retires once the ride is rated', (tester) async {
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();

      // A successful submit is what marks the ride rated; the server keeps no
      // record the app can read back, so the guard is session-local.
      container.read(ratedRideIdsProvider.notifier).state = {'r1'};
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsNothing);
    });

    testWidgets('a mid-trip stage offers no rating', (tester) async {
      await pumpTrip(tester);
      broadcast(status: 'in_progress');
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsNothing);
    });

    testWidgets('a cancelled trip offers no rating', (tester) async {
      await pumpTrip(tester);
      broadcast(status: 'cancelled', cancelledBy: 'rider');
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsNothing);
    });
  });

  group('cancelling', () {
    testWidgets('the cancel button confirms before calling the endpoint',
        (tester) async {
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      stubPost();

      await tester.tap(find.byKey(const Key('trip-cancel-button')));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this trip?'), findsOneWidget);

      await tester.tap(find.text('Keep driving'));
      await tester.pumpAndSettle();
      verifyNever(() => mockDio.post(any(), data: any(named: 'data')));

      await tester.tap(find.byKey(const Key('trip-cancel-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel trip'));
      await tester.pump();
      await tester.pump();

      verify(() => mockDio.post(ApiEndpoints.driverRideCancel('r1'),
          data: any(named: 'data'))).called(1);
      expect(find.text('Trip cancelled'), findsOneWidget);
    });

    testWidgets('a rider cancellation is reported and clears the trip',
        (tester) async {
      await pumpTrip(tester);
      broadcast(status: 'cancelled', cancelledBy: 'rider');
      await tester.pump();

      expect(find.text('Cancelled by the rider.'), findsOneWidget);
      expect(find.byKey(const Key('trip-cancel-button')), findsNothing);

      await tester.tap(find.byKey(const Key('trip-done-button')));
      await tester.pumpAndSettle();

      expect(find.text('home screen'), findsOneWidget);
      expect(rideState.state.currentRide, isNull);
    });
  });

  group('route drawing', () {
    testWidgets('requests the route and draws the road polyline',
        (tester) async {
      stubRouteGet();
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      await tester.pump();

      verify(() => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: any(named: 'queryParameters'),
          )).called(1);

      final lines = polylines(tester);
      // Straight-line underlay + the road-following route.
      expect(lines.length, 2);
      expect(lines[1].points.length, 3);
      expect(lines[1].color, Colors.blue);
      expect(find.textContaining('4.2 km'), findsOneWidget);
    });

    testWidgets('a failed route falls back to the dashed straight line',
        (tester) async {
      when(() => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      )).thenThrow(DioException(requestOptions: RequestOptions(path: '/')));

      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      await tester.pump();

      final lines = polylines(tester);
      expect(lines.length, 1);
      expect(lines.first.pattern.segments, isNotNull);
      expect(find.textContaining('km'), findsNothing);
    });

    testWidgets('an out-of-coverage estimate is dashed too', (tester) async {
      when(() => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      )).thenAnswer((_) async => jsonResponse({
            'polyline': [
              {'lat': pickupLat, 'lng': pickupLng},
              {'lat': dropoffLat, 'lng': dropoffLng},
            ],
            'total_distance_m': 2900,
            'total_duration_s': 260,
            'is_estimate': true,
          }));

      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      await tester.pump();

      final lines = polylines(tester);
      expect(lines.length, 1);
      expect(lines.first.pattern.segments, isNotNull);
      expect(find.textContaining('Estimated 2.9 km'), findsOneWidget);
    });
  });
}
