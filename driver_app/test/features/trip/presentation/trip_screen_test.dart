import 'dart:async';

import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/location/location_service.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/features/home/providers/availability_notifier.dart';
import 'package:driver_app/features/rides/presentation/rate_sheet.dart';
import 'package:driver_app/features/trip/providers/trip_notifier.dart';
import 'package:driver_app/features/trip/presentation/trip_screen.dart';
import 'package:driver_app/features/rides/data/rated_rides_provider.dart';

import '../../../support/trip_fixtures.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockDriverWebSocketService extends Mock
    implements DriverWebSocketService {}

/// Counts arrival-support pushes without touching a geolocator platform
/// channel or the network.
class FakeLocationService extends LocationService {
  FakeLocationService({
    required super.apiClient,
    required super.availabilityNotifier,
  }) : super(positionStreamProvider: () => const Stream<Position>.empty());

  int publishCount = 0;

  @override
  void publishLastPosition({bool force = true}) {
    publishCount++;
  }
}

void main() {
  const pickupLat = tripPickupLat, pickupLng = tripPickupLng;
  const dropoffLat = tripDropoffLat, dropoffLng = tripDropoffLng;

  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late RideStateNotifier rideState;
  late FakeLocationService fakeLocation;
  late ProviderContainer container;

  Response jsonResponse(Map<String, dynamic> data) => Response(
    requestOptions: RequestOptions(path: '/stub'),
    statusCode: 200,
    data: data,
  );

  /// Stubs `GET /driver/ratings`: the driver has rated exactly [rideIds].
  /// Defaults to "rated nothing" — the only state in which the post-trip
  /// prompt may appear.
  void stubRatings(List<String> rideIds) {
    when(
      () => mockDio.get(
        ApiEndpoints.driverRatings,
        queryParameters: any(named: 'queryParameters'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer(
      (_) async => jsonResponse({
        'ratings': [
          for (final id in rideIds)
            {
              'id': 'rating-$id',
              'ride_id': id,
              'rater_role': 'driver',
              'score': 5,
              'comment': '',
              'created_at': '2026-09-01T12:00:00Z',
            },
        ],
        'total': rideIds.length,
        'page': 1,
        'per_page': ratedRidesPageSize,
        'total_pages': 1,
      }),
    );
  }

  /// Holds the rated list open, so the in-flight window is observable.
  Completer<Response> gateRatings() {
    final gate = Completer<Response>();
    when(
      () => mockDio.get(
        ApiEndpoints.driverRatings,
        queryParameters: any(named: 'queryParameters'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => gate.future);
    return gate;
  }

  /// Builds the production provider graph with the two location seams
  /// overridden, so no test touches the geolocator platform channel.
  ProviderContainer buildContainer({
    GeoPoint? position = const GeoPoint(pickupLat, pickupLng),
    Future<LatLng?> Function()? fix,
  }) {
    final built = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        // No tiles: the map must not touch the network under flutter_test.
        mapTileLayerProvider.overrideWith((ref, config) => null),
        lastPositionProvider.overrideWith((ref) => position),
        driverCurrentPositionProvider.overrideWithValue(
          fix ?? () async => null,
        ),
        locationServiceProvider.overrideWith(
          (ref) => fakeLocation = FakeLocationService(
            apiClient: mockApiClient,
            availabilityNotifier: ref.read(availabilityProvider.notifier),
          ),
        ),
      ],
    );
    // Force the lazy override to construct the fake even in cases that never
    // reach an accepted ride, so tests can assert on its counter.
    fakeLocation = built.read(locationServiceProvider) as FakeLocationService;
    return built;
  }

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    final mockWs = MockDriverWebSocketService();
    when(() => mockWs.events).thenAnswer((_) => const Stream<WsEvent>.empty());
    rideState = RideStateNotifier(mockWs, apiClient: MockApiClient());

    container = buildContainer();
    addTearDown(container.dispose);

    // The rated list is server-gated: default it to "rated nothing", the only
    // state in which the post-trip prompt may appear. A case that cares about a
    // different list re-stubs it after this.
    stubRatings(const []);

    // The trip layer loads the sibling `stops` once per ride.
    when(() => mockDio.get(ApiEndpoints.driverRideById('r1'))).thenAnswer(
      (_) async => jsonResponse({
        'ride': {
          'id': 'r1',
          'status': 'accepted',
          'pickup_lat': pickupLat,
          'pickup_lng': pickupLng,
          'dropoff_lat': dropoffLat,
          'dropoff_lng': dropoffLng,
        },
        'stops': [
          {
            'sequence': 1,
            'kind': 'stop',
            'lat': 9.9400,
            'lng': -84.0900,
            'address': 'Midpoint Cafe',
          },
          {
            'sequence': 2,
            'kind': 'destination',
            'lat': dropoffLat,
            'lng': dropoffLng,
            'address': 'Airport',
          },
        ],
      }),
    );
  });

  void broadcast({
    String rideId = 'r1',
    String status = 'accepted',
    Map<String, dynamic>? fare,
    String? cancelledBy,
    double? dropoffLat,
    double? dropoffLng,
    String? dropoffAddress,
  }) {
    rideState.onWsEvent(
      rideUpdated(
        rideId: rideId,
        status: status,
        fare: fare,
        cancelledBy: cancelledBy,
        includePlaces: true,
        dropoffLat: dropoffLat,
        dropoffLng: dropoffLng,
        dropoffAddress: dropoffAddress,
      ),
    );
  }

  void stubPut(String status, {double totalFare = 13.2}) {
    when(() => mockDio.put(any(), data: any(named: 'data'))).thenAnswer(
      (_) async => jsonResponse({
        'ride': {
          'id': 'r1',
          'status': status,
          'pickup_lat': pickupLat,
          'dropoff_lat': dropoffLat,
          'total_fare': totalFare,
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
    when(
      () => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => jsonResponse({
        'polyline': [
          {'lat': pickupLat, 'lng': pickupLng},
          {'lat': pickupLat + 0.01, 'lng': pickupLng + 0.01},
          {'lat': dropoffLat, 'lng': dropoffLng},
        ],
        'total_distance_m': 4200,
        'total_duration_s': 380,
      }),
    );
  }

  /// Answers every navigation request with the actual requested leg (from →
  /// to), so the drawn road matches the stage the screen is in.
  void stubLegRoute({bool isEstimate = false}) {
    when(
      () => mockDio.get(
        ApiEndpoints.navigationRoute,
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer((invocation) async {
      final query =
          invocation.namedArguments[#queryParameters] as Map<String, dynamic>;
      final fromLat = (query['from_lat'] as num).toDouble();
      final fromLng = (query['from_lng'] as num).toDouble();
      final toLat = (query['to_lat'] as num).toDouble();
      final toLng = (query['to_lng'] as num).toDouble();
      return jsonResponse({
        'polyline': [
          {'lat': fromLat, 'lng': fromLng},
          {'lat': toLat, 'lng': toLng},
        ],
        'total_distance_m': 1200,
        'total_duration_s': 110,
        'is_estimate': isEstimate,
      });
    });
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

  /// Mounts `/trip` by pushing it from `/home`, the production path
  /// (`home_screen.dart` calls `context.push('/trip')`). Only on this stack —
  /// with a route below `/trip` — could Flutter synthesize an implicit back
  /// arrow for a null `AppBar.leading`, so this is the stack the terminal
  /// suppression must be exercised on.
  Future<GoRouter> pumpTripPushed(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/home',
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
    router.push('/trip');
    await tester.pump();
    await tester.pump();
    return router;
  }

  List<Polyline> polylines(WidgetTester tester) =>
      tester.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines;

  /// The live camera of the mounted `FlutterMap`.
  MapCamera mapCamera(WidgetTester tester) =>
      tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;

  Finder locateButton() => find.byKey(const Key('map-locate-button'));

  /// Let the route request and the button's post-frame auto-fit resolve.
  Future<void> pumpRoute(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
  }

  group('arrival while already at the pickup', () {
    testWidgets('mounting an accepted trip re-publishes the cached fix', (
      tester,
    ) async {
      // The driver accepted while stationary at the pickup: geolocator emits
      // no further fix (10 m distanceFilter), so the server geofence only
      // runs if the screen pushes the cached one.
      broadcast(status: 'accepted');
      await pumpTrip(tester);
      await tester.pump();

      expect(fakeLocation.publishCount, greaterThanOrEqualTo(1));
    });

    testWidgets('a server-confirmed accept after mount publishes again', (
      tester,
    ) async {
      // The accept is server-confirmed, but a later `ride.updated` acceptance
      // must still trigger a fresh fix.
      await pumpTrip(tester);
      await tester.pump();
      expect(fakeLocation.publishCount, 0);

      broadcast(status: 'accepted');
      await tester.pump();

      expect(fakeLocation.publishCount, greaterThanOrEqualTo(1));
    });
  });

  group('without a held ride', () {
    testWidgets('shows no active trip', (tester) async {
      await pumpTrip(tester);

      expect(find.text('No active trip'), findsOneWidget);
      expect(find.byKey(const Key('trip-primary-button')), findsNothing);
    });

    testWidgets('shows the shared back arrow while the trip is not terminal', (
      tester,
    ) async {
      await pumpTrip(tester);

      // Non-terminal: the driver can back out, so the shared glyph renders.
      expect(find.byType(AppBackButton), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });
  });

  group('terminal back-arrow suppression', () {
    testWidgets('a completed trip hides the back arrow', (tester) async {
      await pumpTripPushed(tester);
      broadcast(status: 'completed');
      await tester.pump();

      // Terminal on the production push stack: no explicit glyph and — with
      // `automaticallyImplyLeading: false` — no implicit `Icons.arrow_back`
      // either, even though `/home` still sits below `/trip`.
      expect(find.byType(AppBackButton), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('a cancelled trip hides the back arrow', (tester) async {
      await pumpTripPushed(tester);
      broadcast(status: 'cancelled', cancelledBy: 'rider');
      await tester.pump();

      expect(find.byType(AppBackButton), findsNothing);
      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('a non-terminal pushed trip keeps the shared back arrow', (
      tester,
    ) async {
      await pumpTripPushed(tester);

      // Non-terminal on the production stack: the shared glyph is the only
      // back affordance and it pops back to `/home`.
      expect(find.byType(AppBackButton), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byType(AppBackButton));
      await tester.pumpAndSettle();
      expect(find.text('home screen'), findsOneWidget);
    });
  });

  group('stage buttons', () {
    testWidgets('a ride held before the screen opens is picked up', (
      tester,
    ) async {
      // The home screen pushes /trip *because* a ride is already held, and the
      // launch restore adopts one before the first frame.
      broadcast(status: 'in_progress');
      await pumpTrip(tester);

      expect(find.text('Driving to the dropoff'), findsOneWidget);
      expect(find.text('Complete Trip'), findsOneWidget);
    });

    testWidgets(
      'enrouteToPickup has no arrival button; the broadcast advances it',
      (tester) async {
        await pumpTrip(tester);
        broadcast();
        await tester.pump();

        // Arrival is server-owned: no manual primary button exists while en route.
        expect(find.text('Drive to the pickup'), findsOneWidget);
        expect(find.byKey(const Key('trip-primary-button')), findsNothing);
        expect(find.text('Arrived at pickup'), findsNothing);

        // The server's proximity geofence broadcasts `driver_arrived`; the app
        // reflects it without sending anything.
        broadcast(status: 'driver_arrived');
        await tester.pump();

        expect(find.text('Arrived at the pickup'), findsOneWidget);
        expect(find.text('Start trip'), findsOneWidget);
        verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
      },
    );

    testWidgets('arrived starts the trip and then shows the complete button', (
      tester,
    ) async {
      await pumpTrip(tester);
      broadcast(status: 'driver_arrived');
      await tester.pump();
      stubPut('in_progress');

      expect(find.text('Start trip'), findsOneWidget);
      await tester.tap(find.byKey(const Key('trip-primary-button')));
      await tester.pump();
      await tester.pump();

      final captured = verify(
        () => mockDio.put(
          ApiEndpoints.driverRideStatus('r1'),
          data: captureAny(named: 'data'),
        ),
      ).captured;
      expect((captured.first as Map)['status'], 'in_progress');
      expect(find.text('Driving to the dropoff'), findsOneWidget);
      expect(find.text('Complete Trip'), findsOneWidget);
      // In progress the driver can no longer cancel.
      expect(find.byKey(const Key('trip-cancel-button')), findsNothing);
      expect(find.text('Rider can cancel from here'), findsOneWidget);
    });

    testWidgets('driving asks for confirmation before completing', (
      tester,
    ) async {
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
        () => mockDio.put(
          ApiEndpoints.driverRideStatus('r1'),
          data: captureAny(named: 'data'),
        ),
      ).captured;
      expect((captured.first as Map)['status'], 'completed');
      expect(find.text('Trip completed'), findsOneWidget);
    });

    testWidgets('a completed trip shows the fare and returns home', (
      tester,
    ) async {
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

      // No currency on the fare, so the amount renders bare — never invented.
      expect(find.text('11.80'), findsOneWidget);
      expect(find.text('2.50'), findsOneWidget);

      await tester.tap(find.byKey(const Key('trip-done-button')));
      await tester.pumpAndSettle();

      expect(find.text('home screen'), findsOneWidget);
      expect(rideState.state.currentRide, isNull);
    });

    testWidgets(
      'shows the API currency, conditions multiplier and climb note',
      (tester) async {
        await pumpTrip(tester);
        broadcast(
          status: 'completed',
          fare: {
            'base_fare': 2.5,
            'distance_fare': 6.0,
            'time_fare': 3.3,
            'surge_multiplier': 1.2,
            'total': 11.8,
            'currency': 'USD',
            'grade_uplift_pct': 0.05,
          },
        );
        await tester.pump();

        expect(find.text('USD11.80'), findsOneWidget);
        expect(find.text('USD2.50'), findsOneWidget);
        expect(find.text('Conditions multiplier'), findsOneWidget);
        expect(find.text('×1.20'), findsOneWidget);
        expect(find.text('climb +5.0%'), findsOneWidget);
      },
    );

    testWidgets('omits the currency, uplift and multiplier when absent', (
      tester,
    ) async {
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

      expect(find.textContaining('USD'), findsNothing);
      expect(find.textContaining('climb'), findsNothing);
      expect(find.text('Conditions multiplier'), findsNothing);
    });
  });

  group('final charge on completion', () {
    testWidgets(
      'the completion broadcast replaces the booked fare with the final',
      (tester) async {
        await pumpTrip(tester);
        // While the trip runs the held ride carries the booked quote, which the
        // driver must never see after completion.
        broadcast(
          status: 'in_progress',
          fare: {'base_fare': 2.0, 'total': 10.0},
        );
        await tester.pump();

        // The completion event carries the fare recomputed from actuals.
        broadcast(
          status: 'completed',
          fare: {
            'base_fare': 2.5,
            'distance_fare': 6.0,
            'time_fare': 3.3,
            'total': 13.2,
          },
        );
        await tester.pump();

        expect(find.text('13.20'), findsOneWidget);
        expect(find.text('2.50'), findsOneWidget);
        expect(find.text('10.00'), findsNothing);
      },
    );

    testWidgets(
      'the REST completion response flows its final total to the screen',
      (tester) async {
        await pumpTrip(tester);
        broadcast(status: 'in_progress', fare: {'total': 10.0});
        await tester.pump();
        stubPut('completed', totalFare: 13.2);

        await tester.tap(find.byKey(const Key('trip-primary-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Confirm'));
        await tester.pump();
        await tester.pump();

        expect(find.text('Trip completed'), findsOneWidget);
        expect(find.text('13.20'), findsOneWidget);
        expect(find.text('10.00'), findsNothing);
      },
    );

    testWidgets('a completion with no fare keeps the placeholder', (
      tester,
    ) async {
      await pumpTrip(tester);
      broadcast(status: 'completed');
      await tester.pump();

      // Every row is null, so every row shows the placeholder — never a
      // fabricated 0.00.
      expect(find.text('—'), findsNWidgets(4));
      expect(find.textContaining('0.00'), findsNothing);
    });
  });

  group('rating after the trip', () {
    void completeTrip() {
      broadcast(status: 'completed', fare: {'base_fare': 2.5, 'total': 11.8});
    }

    testWidgets('the post screen offers to rate the rider', (tester) async {
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();
      // The tri-state is resolved by a FutureProvider now: it needs one more
      // microtask to turn the loaded seed into an `unrated` prompt.
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsOneWidget);
      expect(find.text('Rate the rider'), findsOneWidget);
    });

    testWidgets('tapping it opens the sheet for the completed ride', (
      tester,
    ) async {
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(const Key('trip-rate-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.byType(RateSheet), findsOneWidget);
      expect(find.text('Rate your rider'), findsOneWidget);
    });

    testWidgets('the prompt retires once the server lists the ride as rated', (
      tester,
    ) async {
      stubRatings(['r1']);
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsNothing);
    });

    testWidgets('nothing is offered while the rated list is still loading', (
      tester,
    ) async {
      final gate = gateRatings();
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();

      // Unknown, not unrated: the trip just ended, so claiming the driver
      // never rated it would re-ask for a rating they may already have given.
      expect(find.byKey(const Key('trip-rate-button')), findsNothing);
      expect(find.byKey(const Key('trip-ratings-retry')), findsNothing);

      gate.complete(
        jsonResponse({
          'ratings': const [],
          'total': 0,
          'page': 1,
          'per_page': ratedRidesPageSize,
          'total_pages': 1,
        }),
      );
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsOneWidget);
    });

    testWidgets('a failed rated list hides the prompt and offers a retry', (
      tester,
    ) async {
      when(
        () => mockDio.get(
          ApiEndpoints.driverRatings,
          queryParameters: any(named: 'queryParameters'),
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(Exception('boom'));
      await pumpTrip(tester);
      completeTrip();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('trip-rate-button')), findsNothing);
      expect(find.text(ratedRidesErrorMessage), findsOneWidget);

      stubRatings(const []);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('trip-ratings-retry')),
          matching: find.byType(TextButton),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text(ratedRidesErrorMessage), findsNothing);
      expect(find.byKey(const Key('trip-rate-button')), findsOneWidget);
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
    testWidgets('the cancel button confirms before calling the endpoint', (
      tester,
    ) async {
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

      verify(
        () => mockDio.post(
          ApiEndpoints.driverRideCancel('r1'),
          data: any(named: 'data'),
        ),
      ).called(1);
      expect(find.text('Trip cancelled'), findsOneWidget);
    });

    testWidgets('a rider cancellation is reported and clears the trip', (
      tester,
    ) async {
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

    DioException httpError(int status) => DioException(
      requestOptions: RequestOptions(path: '/stub'),
      response: Response(
        requestOptions: RequestOptions(path: '/stub'),
        statusCode: status,
      ),
    );

    Future<void> confirmCancel(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('trip-cancel-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel trip'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('a 404 cancel leaves the trip screen for home', (tester) async {
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      when(
        () => mockDio.post(any(), data: any(named: 'data')),
      ).thenThrow(httpError(404));

      await confirmCancel(tester);
      await tester.pumpAndSettle();

      expect(find.text('home screen'), findsOneWidget);
      expect(find.byType(TripScreen), findsNothing);
      expect(rideState.state.currentRide, isNull);
    });

    testWidgets('a 500 cancel shows the error and stays on the trip', (
      tester,
    ) async {
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      when(
        () => mockDio.post(any(), data: any(named: 'data')),
      ).thenThrow(httpError(500));

      await confirmCancel(tester);

      expect(find.byType(TripScreen), findsOneWidget);
      expect(
        find.text('Could not cancel the trip. Please try again.'),
        findsOneWidget,
      );
      expect(rideState.state.currentRide, isNotNull);
    });

    testWidgets(
      'the cancel dialog does not claim the trip returns to dispatch',
      (tester) async {
        await pumpTrip(tester);
        broadcast();
        await tester.pump();

        await tester.tap(find.byKey(const Key('trip-cancel-button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('goes back to dispatch'), findsNothing);
        expect(
          find.textContaining('will not be offered to another driver'),
          findsOneWidget,
        );

        await tester.tap(find.text('Keep driving'));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'a no_driver_available cancel reconcile returns to home without a '
      'cancelled view',
      (tester) async {
        await pumpTrip(tester);
        broadcast();
        await tester.pump();
        when(
          () => mockDio.post(any(), data: any(named: 'data')),
        ).thenThrow(httpError(409));
        when(() => mockDio.get(ApiEndpoints.driverRideById('r1'))).thenAnswer(
          (_) async => jsonResponse({
            'ride': {
              'id': 'r1',
              'status': 'no_driver_available',
              'pickup_lat': pickupLat,
            },
            'stops': const <Map<String, dynamic>>[],
          }),
        );

        await confirmCancel(tester);
        await tester.pumpAndSettle();

        expect(find.text('home screen'), findsOneWidget);
        expect(find.text('Cancelled by the rider.'), findsNothing);
        expect(rideState.state.currentRide, isNull);
      },
    );
  });

  group('route drawing', () {
    testWidgets('requests the route and draws the road polyline', (
      tester,
    ) async {
      stubRouteGet();
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      await tester.pump();

      verify(
        () => mockDio.get(
          ApiEndpoints.navigationRoute,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).called(1);

      final lines = polylines(tester);
      // Straight-line underlay + the road-following route.
      expect(lines.length, 2);
      expect(lines[1].points.length, 3);
      expect(lines[1].color, Colors.blue);
      expect(find.textContaining('4.2 km'), findsOneWidget);
      // The stage action is the shared button.
      expect(find.byType(AppButton), findsWidgets);
    });

    testWidgets('a failed route falls back to the dashed straight line', (
      tester,
    ) async {
      when(
        () => mockDio.get(
          ApiEndpoints.navigationRoute,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenThrow(DioException(requestOptions: RequestOptions(path: '/')));

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
      when(
        () => mockDio.get(
          ApiEndpoints.navigationRoute,
          queryParameters: any(named: 'queryParameters'),
        ),
      ).thenAnswer(
        (_) async => jsonResponse({
          'polyline': [
            {'lat': pickupLat, 'lng': pickupLng},
            {'lat': dropoffLat, 'lng': dropoffLng},
          ],
          'total_distance_m': 2900,
          'total_duration_s': 260,
          'is_estimate': true,
        }),
      );

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

  group('map locate button', () {
    const driverFix = GeoPoint(pickupLat - 0.002, pickupLng - 0.002);

    RouteCache routeCache({
      DateTime? fetchedAt,
      bool isEstimate = false,
      List<Map<String, dynamic>>? polyline,
    }) => RouteCache(
      polyline:
          polyline ??
          [
            {'lat': driverFix.lat, 'lng': driverFix.lng},
            {'lat': pickupLat, 'lng': pickupLng},
          ],
      distance: 1200,
      duration: 110,
      isEstimate: isEstimate,
      originLat: driverFix.lat,
      originLng: driverFix.lng,
      toLat: pickupLat,
      toLng: pickupLng,
      fetchedAt: fetchedAt ?? DateTime(2026, 10, 19),
    );

    test('the material key is next waypoint + status only', () {
      const next = TripWaypoint(
        lat: pickupLat,
        lng: pickupLng,
        address: 'Pickup',
        isPickup: true,
      );
      final ready = routeCache();

      // A `ready → ready` refresh (new `fetchedAt`, even new geometry for the
      // same endpoints) is not material.
      expect(
        driverTripRouteKey(next, ready),
        driverTripRouteKey(
          next,
          routeCache(
            fetchedAt: DateTime(2026, 10, 20),
            polyline: [
              {'lat': driverFix.lat, 'lng': driverFix.lng},
              {'lat': pickupLat + 0.001, 'lng': pickupLng},
              {'lat': pickupLat, 'lng': pickupLng},
            ],
          ),
        ),
      );

      // `none → ready` is material.
      expect(
        driverTripRouteKey(next, null),
        isNot(driverTripRouteKey(next, ready)),
      );

      // A status flip is material.
      expect(
        driverTripRouteKey(next, ready),
        isNot(driverTripRouteKey(next, routeCache(isEstimate: true))),
      );

      // A new next waypoint is material.
      expect(
        driverTripRouteKey(next, ready),
        isNot(
          driverTripRouteKey(
            const TripWaypoint(
              lat: dropoffLat,
              lng: dropoffLng,
              address: 'Airport',
              isDestination: true,
            ),
            ready,
          ),
        ),
      );
    });

    testWidgets('the button sits inside the map region, above the controls', (
      tester,
    ) async {
      broadcast(status: 'accepted');
      await pumpTrip(tester);
      await tester.pump();

      final button = locateButton();
      expect(button, findsOneWidget);
      final mapRect = tester.getRect(find.byType(FlutterMap));
      final buttonRect = tester.getRect(button);
      expect(buttonRect.right, closeTo(mapRect.right - 16, 1));
      expect(buttonRect.bottom, lessThanOrEqualTo(mapRect.bottom));
      expect(buttonRect.top, greaterThanOrEqualTo(mapRect.top));
    });

    testWidgets('the route auto-fits on load and the next press locates', (
      tester,
    ) async {
      container = buildContainer(position: driverFix);
      addTearDown(container.dispose);
      stubLegRoute();
      broadcast(status: 'accepted');
      await pumpTrip(tester);
      await pumpRoute(tester);

      // The shared widget auto-fitted the drawn driver → pickup leg, which is
      // the fit half of the cycle.
      expect(find.byTooltip('Current location'), findsOneWidget);
      final fitted = mapCamera(tester).visibleBounds;
      expect(fitted.contains(LatLng(driverFix.lat, driverFix.lng)), isTrue);
      expect(fitted.contains(const LatLng(pickupLat, pickupLng)), isTrue);

      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();

      final camera = mapCamera(tester);
      expect(camera.center.latitude, closeTo(driverFix.lat, 0.0001));
      expect(camera.center.longitude, closeTo(driverFix.lng, 0.0001));
      expect(camera.zoom, 16);
      expect(find.byTooltip('Fit route'), findsOneWidget);
    });

    testWidgets('the button cycles locate → fit route → locate', (
      tester,
    ) async {
      container = buildContainer(position: driverFix);
      addTearDown(container.dispose);
      stubLegRoute();
      broadcast(status: 'accepted');
      await pumpTrip(tester);
      await pumpRoute(tester);

      // Auto-fit is the fit half; tap 1 locates.
      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();
      var camera = mapCamera(tester);
      expect(camera.center.latitude, closeTo(driverFix.lat, 0.0001));
      expect(camera.center.longitude, closeTo(driverFix.lng, 0.0001));
      expect(camera.zoom, 16);
      expect(find.byTooltip('Fit route'), findsOneWidget);

      // Tap 2 fits the drawn route again.
      await tester.tap(locateButton());
      await tester.pump();
      camera = mapCamera(tester);
      expect(
        camera.visibleBounds.contains(LatLng(driverFix.lat, driverFix.lng)),
        isTrue,
      );
      expect(
        camera.visibleBounds.contains(const LatLng(pickupLat, pickupLng)),
        isTrue,
      );
      expect(find.byTooltip('Current location'), findsOneWidget);

      // Tap 3 locates again.
      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();
      camera = mapCamera(tester);
      expect(camera.center.latitude, closeTo(driverFix.lat, 0.0001));
      expect(camera.center.longitude, closeTo(driverFix.lng, 0.0001));
      expect(camera.zoom, 16);
    });

    testWidgets(
      'a next-waypoint change auto-fits the new leg and the next tap locates',
      (tester) async {
        container = buildContainer(position: driverFix);
        addTearDown(container.dispose);
        // No intermediate stops: the destination is the next waypoint as soon
        // as the trip starts.
        when(() => mockDio.get(ApiEndpoints.driverRideById('r1'))).thenAnswer(
          (_) async => jsonResponse({
            'ride': {
              'id': 'r1',
              'status': 'accepted',
              'pickup_lat': pickupLat,
              'pickup_lng': pickupLng,
              'dropoff_lat': dropoffLat,
              'dropoff_lng': dropoffLng,
            },
            'stops': const <Map<String, dynamic>>[],
          }),
        );
        stubLegRoute();
        broadcast(status: 'accepted');
        await pumpTrip(tester);
        await pumpRoute(tester);

        // Consume the initial auto-fit's locate half so the cycle is on fit.
        await tester.tap(locateButton());
        await tester.pump();
        await tester.pump();
        expect(find.byTooltip('Fit route'), findsOneWidget);

        const movedLat = 9.99, movedLng = -84.2;
        broadcast(
          status: 'in_progress',
          dropoffLat: movedLat,
          dropoffLng: movedLng,
          dropoffAddress: 'Moved',
        );
        await pumpRoute(tester);

        // The material next-waypoint change re-fits the new driver → dropoff
        // leg without any screen-side scheduling.
        final fitted = mapCamera(tester).visibleBounds;
        expect(fitted.contains(const LatLng(movedLat, movedLng)), isTrue);
        expect(find.byTooltip('Current location'), findsOneWidget);

        await tester.tap(locateButton());
        await tester.pump();
        await tester.pump();
        final located = mapCamera(tester);
        expect(located.center.latitude, closeTo(driverFix.lat, 0.0001));
        expect(located.center.longitude, closeTo(driverFix.lng, 0.0001));
        expect(located.zoom, 16);
      },
    );

    testWidgets('a locate with no fix tells the truth and moves nothing', (
      tester,
    ) async {
      container = buildContainer(position: null, fix: () async => null);
      addTearDown(container.dispose);
      broadcast(status: 'accepted');
      await pumpTrip(tester);
      await pumpRoute(tester);

      final before = mapCamera(tester).center;
      expect(find.byTooltip('Current location'), findsOneWidget);

      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();

      expect(find.text('Waiting for your location…'), findsOneWidget);
      // The failed locate stays on locate; the camera did not move.
      expect(find.byTooltip('Current location'), findsOneWidget);
      final after = mapCamera(tester).center;
      expect(after.latitude, closeTo(before.latitude, 1e-9));
      expect(after.longitude, closeTo(before.longitude, 1e-9));
    });

    testWidgets('a failed locate retries the locate on the next press', (
      tester,
    ) async {
      var attempts = 0;
      container = buildContainer(
        position: null,
        fix: () async {
          attempts++;
          return attempts == 1 ? null : const LatLng(9.91, -84.07);
        },
      );
      addTearDown(container.dispose);
      broadcast(status: 'accepted');
      await pumpTrip(tester);
      await pumpRoute(tester);

      final before = mapCamera(tester).center;
      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();

      expect(attempts, 1);
      expect(find.text('Waiting for your location…'), findsOneWidget);
      expect(find.byTooltip('Current location'), findsOneWidget);
      expect(mapCamera(tester).center.latitude, closeTo(before.latitude, 1e-9));

      // The retry succeeds and centers at the shared locate zoom.
      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();

      expect(attempts, 2);
      final camera = mapCamera(tester);
      expect(camera.center.latitude, closeTo(9.91, 0.0001));
      expect(camera.center.longitude, closeTo(-84.07, 0.0001));
      expect(camera.zoom, 16);
    });
  });

  group('route error surfacing', () {
    testWidgets('renders the backend error message when routeError is set', (
      tester,
    ) async {
      await pumpTrip(tester);
      broadcast();
      await tester.pump();
      await tester.pump();

      container.read(tripNotifierProvider.notifier).state = container
          .read(tripNotifierProvider)
          .copyWith(routeError: 'failed to calculate route');
      await tester.pump();

      expect(find.textContaining('failed to calculate route'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      expect(find.byType(AppErrorRow), findsOneWidget);
    });
  });

  group('live destination and itinerary', () {
    testWidgets(
      'a destination-only update re-requests the route to the new dropoff',
      (tester) async {
        stubRouteGet();
        await pumpTrip(tester);
        // Stand at the intermediate stop so the destination is the next target.
        container.read(lastPositionProvider.notifier).state = const GeoPoint(
          9.9400,
          -84.0900,
        );
        broadcast(status: 'in_progress');
        await tester.pump();
        await tester.pump();

        // The stage does not change, but the destination moved: the route must be
        // re-requested to the new dropoff.
        broadcast(
          status: 'in_progress',
          dropoffLat: 9.99,
          dropoffLng: -84.2,
          dropoffAddress: 'Moved',
        );
        await tester.pump();
        await tester.pump();

        // `verify` consumes matched invocations, so assert the whole set once.
        final captured = verify(
          () => mockDio.get(
            ApiEndpoints.navigationRoute,
            queryParameters: captureAny(named: 'queryParameters'),
          ),
        ).captured;
        expect(captured, hasLength(2));
        expect((captured.last as Map)['to_lat'], 9.99);
        expect((captured.last as Map)['to_lng'], -84.2);
      },
    );

    testWidgets('the drawer lists every waypoint and marks the next', (
      tester,
    ) async {
      await pumpTrip(tester);
      broadcast(status: 'in_progress');
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('trip-itinerary')), findsOneWidget);
      expect(find.text('Central Park'), findsOneWidget);
      expect(find.text('Midpoint Cafe'), findsOneWidget);
      expect(find.text('Airport'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);
    });

    testWidgets('the map marks only the next waypoint plus the driver', (
      tester,
    ) async {
      await pumpTrip(tester);
      broadcast(status: 'in_progress');
      await tester.pump();
      await tester.pump();

      final layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
      // Next waypoint + driver, never the whole itinerary.
      expect(layer.markers, hasLength(2));
    });

    testWidgets('moving to an intermediate stop advances the route target', (
      tester,
    ) async {
      stubRouteGet();
      await pumpTrip(tester);
      broadcast(status: 'in_progress');
      await tester.pump();
      await tester.pump();

      container.read(lastPositionProvider.notifier).state = const GeoPoint(
        9.9400,
        -84.0900,
      );
      await tester.pump();
      await tester.pump();

      // At the pickup the target was the intermediate stop; now the
      // destination is the next target, a new cache key.
      final captured = verify(
        () => mockDio.get(
          ApiEndpoints.navigationRoute,
          queryParameters: captureAny(named: 'queryParameters'),
        ),
      ).captured;
      expect(captured, hasLength(2));
      expect((captured.last as Map)['to_lat'], dropoffLat);
      expect((captured.last as Map)['to_lng'], dropoffLng);
    });
  });
}
