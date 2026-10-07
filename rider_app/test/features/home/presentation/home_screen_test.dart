import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/multi_leg_route_provider.dart';
import 'package:rider_app/features/home/model/place.dart';
import 'package:rider_app/features/home/presentation/home_screen.dart';

const pickupPlace = Place(
  id: 'pickup',
  name: 'Pickup Point',
  address: 'Main St',
  lat: 9.9281,
  lng: -84.0907,
);

const destinationPlace = Place(
  id: 'dropoff',
  name: 'Dropoff Point',
  address: 'Airport Rd',
  lat: 9.94,
  lng: -84.10,
);

const stopPlace = Place(
  id: 'stop',
  name: 'Coffee Shop',
  address: 'Cafe St',
  lat: 9.934,
  lng: -84.095,
);

/// A road-shaped answer with the API's three-point geometry (start, road
/// mid-point, end) — deliberately not the straight two-point client line, so a
/// test can tell which one the map drew.
Map<String, dynamic> routeBody({required bool estimate}) => {
      'polyline': [
        {'lat': 9.9281, 'lng': -84.0907},
        {'lat': 9.934, 'lng': -84.095},
        {'lat': 9.94, 'lng': -84.10},
      ],
      'total_distance_m': 1500.0,
      'total_duration_s': 180.0,
      'is_estimate': estimate,
    };

/// A road-shaped answer that reflects the requested leg, so a multi-leg
/// preview is visibly built from its legs rather than one collapsed line.
Map<String, dynamic> legRouteBody(RequestOptions options) {
  final fromLat = double.parse(options.queryParameters['from_lat'].toString());
  final fromLng = double.parse(options.queryParameters['from_lng'].toString());
  final toLat = double.parse(options.queryParameters['to_lat'].toString());
  final toLng = double.parse(options.queryParameters['to_lng'].toString());
  return {
    'polyline': [
      {'lat': fromLat, 'lng': fromLng},
      {'lat': (fromLat + toLat) / 2, 'lng': (fromLng + toLng) / 2},
      {'lat': toLat, 'lng': toLng},
    ],
    'total_distance_m': 1500.0,
    'total_duration_s': 180.0,
    'is_estimate': false,
  };
}

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late ProviderContainer container;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
    container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(apiClient)],
    );
    addTearDown(container.dispose);
    // Watched once both pins exist; keep it quiet so the only unconsumed
    // request in a test is the one under assertion.
    dioAdapter.onGet(
      ApiEndpoints.nearbyDrivers,
      (server) => server.reply(200, {'drivers': <dynamic>[]}),
    );
  });

  Widget buildApp({
    Place? pickup,
    Place? destination,
    Place? addStopResult,
  }) {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          // `Material` (not `Scaffold`): production's shell owns the only
          // Scaffold, so the mount assertion below still holds.
          builder: (_, _) => Material(
            child: HomeScreen(
              initialPickup: pickup,
              initialDestination: destination,
            ),
          ),
        ),
        // The add-stop round trip. Production routes this to the real search
        // screen; the test pops a fixed `Place` so the result contract is what
        // is under test, not the search UI.
        if (addStopResult != null)
          GoRoute(
            path: '/location-search',
            builder: (_, _) => Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (context.mounted) context.pop<Place>(addStopResult);
                });
                return const Scaffold(body: SizedBox.shrink());
              },
            ),
          ),
      ],
    );
    addTearDown(router.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// Let the `navigationRouteProvider` request resolve. Small positive pumps
  /// fire Dio's zero-duration timer without advancing anything else.
  Future<void> pumpRoute(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Mount the seeded home screen on a tall surface. The bottom sheet is 25% of
  /// the viewport, so the default 600 logical px would clip the route info row
  /// out of the list's build window and make it unfindable.
  Future<void> pumpHome(
    WidgetTester tester, {
    Place? pickup,
    Place? destination,
    Place? addStopResult,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp(
      pickup: pickup,
      destination: destination,
      addStopResult: addStopResult,
    ));
    await pumpRoute(tester);
  }

  Polyline? drawnPolyline(WidgetTester tester) {
    final found = find.byType(PolylineLayer);
    if (found.evaluate().isEmpty) return null;
    final layer = tester.widget<PolylineLayer>(found);
    return layer.polylines.isEmpty ? null : layer.polylines.first;
  }

  testWidgets('shows map and bottom sheet on home screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    // Home is body-only: the `RiderShell` owns the `Scaffold` + drawer, so
    // pumping the screen alone must not introduce one.
    expect(find.byType(Scaffold), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('booking flow: shows destination field and request trip button', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pump();

    expect(find.text('Where to?'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // [map] route-failure honesty: the preview mirrors the active trip.
  // ---------------------------------------------------------------------------

  testWidgets('a 200 road route is drawn solid blue from the API geometry', (
    WidgetTester tester,
  ) async {
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.reply(200, routeBody(estimate: false)),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
    );

    final line = drawnPolyline(tester);
    expect(line, isNotNull);
    expect(line!.color, Colors.blue);
    expect(line.pattern, const StrokePattern.solid());
    // The API's midpoint, not the client's straight line.
    expect(line.points, hasLength(3));
    expect(line.points[1], const LatLng(9.934, -84.095));
    expect(find.textContaining('Estimated '), findsNothing);
    expect(find.text('Retry'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'a 200 is_estimate is dashed from the API geometry and labeled "Estimated "',
      (WidgetTester tester) async {
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.reply(200, routeBody(estimate: true)),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
    );

    final line = drawnPolyline(tester);
    expect(line, isNotNull);
    expect(line!.color, Colors.grey);
    expect(line.pattern, isNot(const StrokePattern.solid()));
    // The estimate keeps the API's geometry — never the client straight line.
    expect(line.points, hasLength(3));
    expect(line.points[1], const LatLng(9.934, -84.095));
    expect(find.textContaining('Estimated '), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 500 route response draws nothing and surfaces message + Retry',
      (WidgetTester tester) async {
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.reply(500, {
        'error': {'code': 'INTERNAL', 'message': 'failed to calculate route'},
      }),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
    );

    expect(drawnPolyline(tester), isNull,
        reason: 'an outage must not synthesize a straight line');
    expect(find.text('failed to calculate route'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a 422 route response draws nothing and surfaces message + Retry',
      (WidgetTester tester) async {
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.reply(422, {
        'error': {'code': 'VALIDATION_ERROR', 'message': 'invalid coordinates'},
      }),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
    );

    expect(drawnPolyline(tester), isNull);
    expect(find.text('invalid coordinates'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'a failed refresh keeps the previous road route, never a straight swap',
      (WidgetTester tester) async {
    var calls = 0;
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, (_) {
        calls++;
        if (calls == 1) return routeBody(estimate: false);
        // The refresh answers malformed: a failure, not a route.
        return {'polyline': <dynamic>[], 'is_estimate': false};
      }),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
    );

    final before = drawnPolyline(tester);
    expect(before!.color, Colors.blue);
    expect(before.points, hasLength(3));

    // Refresh the same family instance; Riverpod keeps the previous value on
    // the resulting error (`copyWithPrevious`).
    container.invalidate(multiLegRouteProvider(const RoutePlan(
      fromLat: 9.9281,
      fromLng: -84.0907,
      toLat: 9.94,
      toLng: -84.10,
    )));
    await pumpRoute(tester);

    final after = drawnPolyline(tester);
    expect(after, isNotNull, reason: 'the previous road route is retained');
    expect(after!.color, Colors.blue);
    expect(after.points, hasLength(3),
        reason: 'never a two-point straight-line swap');
    expect(after.points[1], const LatLng(9.934, -84.095));
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('No road route is available'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // ---------------------------------------------------------------------------
  // [multi] pre-booking stop list + fare honesty.
  // ---------------------------------------------------------------------------

  testWidgets(
      'adding a stop routes through /location-search and previews every leg',
      (WidgetTester tester) async {
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, legRouteBody),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      addStopResult: stopPlace,
    );

    // Before any stop: one pickup→destination leg, and no fare caveat.
    expect(drawnPolyline(tester)!.points, hasLength(3));
    expect(find.byKey(const ValueKey<String>('stops-fare-note')), findsNothing);

    await tester.tap(find.byKey(const ValueKey<String>('add-stop-button')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await pumpRoute(tester);

    // The picked place lands in the ordered stop list.
    expect(find.text('Coffee Shop'), findsOneWidget);
    // pickup → stop → destination: two legs concatenated, sharing the stop.
    final line = drawnPolyline(tester);
    expect(line, isNotNull);
    expect(line!.points, hasLength(5));
    expect(line.points[2], const LatLng(9.934, -84.095));
    expect(line.points.last, const LatLng(9.94, -84.10));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'the fare caveat is shown and the estimate is still pickup→destination only',
      (WidgetTester tester) async {
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, legRouteBody),
    );
    final estimateRequests = <Map<String, dynamic>>[];
    dioAdapter.onGet(
      ApiEndpoints.priceEstimate,
      (server) => server.replyCallback(200, (options) {
        estimateRequests.add(Map<String, dynamic>.from(options.queryParameters));
        return {
          'estimates': [
            {
              'vehicle_type': 'sedan',
              'base_fare': 2.5,
              'distance_fare': 3.1,
              'time_fare': 0.9,
              'surge_multiplier': 1.0,
              'total': 6.5,
              'currency': 'USD',
              'demand_multiplier': 1.0,
              'supply_multiplier': 1.0,
              'grade_uplift_pct': 0.0,
            }
          ],
        };
      }),
    );

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      addStopResult: stopPlace,
    );

    await tester.tap(find.byKey(const ValueKey<String>('add-stop-button')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await pumpRoute(tester);

    // The limitation is named instead of inventing a stop-inclusive price.
    expect(
      find.byKey(const ValueKey<String>('stops-fare-note')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Stops are not included in the price estimate'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Request Trip'));
    await tester.pump();
    await tester.tap(find.text('Request Trip'));
    await pumpRoute(tester);

    // The priced request is a single pickup/dropoff pair — no stop coordinate
    // is ever sent, so no client-side stop fare exists to disagree with.
    expect(estimateRequests, hasLength(1));
    expect(estimateRequests.single.keys.toSet(), {
      'pickup_lat',
      'pickup_lng',
      'dropoff_lat',
      'dropoff_lng',
    });
    expect(estimateRequests.single['dropoff_lat'], destinationPlace.lat);
    expect(estimateRequests.single['dropoff_lng'], destinationPlace.lng);

    await tester.pumpWidget(const SizedBox());
  });
}
