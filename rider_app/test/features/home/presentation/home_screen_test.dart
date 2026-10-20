import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/platform/sheet_drag_handle.dart';
import 'package:rider_app/features/home/data/location_service.dart';
import 'package:rider_app/features/home/data/multi_leg_route_provider.dart';
import 'package:rider_app/features/home/data/pickup_memory_provider.dart';
import 'package:rider_app/features/home/model/place.dart';
import 'package:rider_app/features/home/presentation/home_screen.dart';
import 'package:rider_app/features/home/presentation/location_search_screen.dart';

/// A configurable [LocationService] so the widget tests never touch the platform
/// location channel (which never answers under `flutter_test`).
class FakeLocationService implements LocationService {
  LocationAvailability availability = LocationAvailability.granted;
  Position? position;
  int openAppSettingsCalls = 0;
  int openLocationSettingsCalls = 0;

  @override
  Future<LocationAvailability> requestAvailability() async => availability;

  @override
  Future<Position?> getCurrentPosition() async => position;

  @override
  Future<bool> openAppSettings() async {
    openAppSettingsCalls++;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    openLocationSettingsCalls++;
    return true;
  }
}

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

Position testPosition(double lat, double lng) => Position(
  longitude: lng,
  latitude: lat,
  timestamp: DateTime.utc(2026),
  accuracy: 1,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
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
  late FakeLocationService fakeLocation;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
    fakeLocation = FakeLocationService();
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(apiClient),
        locationServiceProvider.overrideWithValue(fakeLocation),
        // No tiles: the map must not touch the network under flutter_test.
        mapTileLayerProvider.overrideWith((ref, config) => null),
      ],
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
    Place? pickupResult,
    Place? destinationResult,
    PickupMemory? pickupMemory,
    List<Map<String, dynamic>>? searchPushes,
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
              pickupMemory: pickupMemory,
            ),
          ),
        ),
        // The destination / add-stop / pickup-search round trip. Production
        // routes this to the real search screen, so the **real**
        // `LocationSearchScreen` is mounted here with the pushed bias. The
        // screen still records the pushed bias `extra` and pops a fixed `Place`
        // per hint, so the push contract (bias + which field) stays under test.
        // The screen's own blocking branch is covered by the negative-control
        // pair in `location_search_screen_test.dart`.
        if (addStopResult != null ||
            pickupResult != null ||
            destinationResult != null)
          GoRoute(
            path: '/location-search',
            builder: (_, state) {
              final extra =
                  (state.extra as Map?)?.cast<String, dynamic>() ?? {};
              searchPushes?.add(extra);
              final hint = extra['hint'] as String?;
              final Place? result = hint == 'Add a stop'
                  ? addStopResult
                  : (hint == 'Pickup location' ||
                        hint == 'Enter pickup location')
                  ? pickupResult
                  : destinationResult;
              return Builder(
                builder: (context) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (context.mounted) context.pop<Place>(result);
                  });
                  return LocationSearchScreen(
                    hint: hint ?? 'Search destinations...',
                    lat: extra['lat'] as double?,
                    lng: extra['lng'] as double?,
                  );
                },
              );
            },
          ),
        // The post-book flow route, so completing a booking (which calls
        // `context.go('/driver-matching')`) has somewhere to land.
        GoRoute(
          path: '/driver-matching',
          builder: (_, _) => const Scaffold(body: Text('matching')),
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
    Place? pickupResult,
    Place? destinationResult,
    PickupMemory? pickupMemory,
    List<Map<String, dynamic>>? searchPushes,
    Size surface = const Size(800, 1600),
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      buildApp(
        pickup: pickup,
        destination: destination,
        addStopResult: addStopResult,
        pickupResult: pickupResult,
        destinationResult: destinationResult,
        pickupMemory: pickupMemory,
        searchPushes: searchPushes,
      ),
    );
    await pumpRoute(tester);
  }

  /// Whether the map is drawing a marker with [icon] anywhere.
  bool hasMarkerIcon(WidgetTester tester, IconData icon) {
    for (final element in find.byType(MarkerLayer).evaluate()) {
      final layer = element.widget as MarkerLayer;
      for (final marker in layer.markers) {
        final child = marker.child;
        if (child is Icon && child.icon == icon) return true;
      }
    }
    return false;
  }

  Polyline? drawnPolyline(WidgetTester tester) {
    final found = find.byType(PolylineLayer);
    if (found.evaluate().isEmpty) return null;
    final layer = tester.widget<PolylineLayer>(found);
    return layer.polylines.isEmpty ? null : layer.polylines.first;
  }

  testWidgets('booking flow: shows destination field and request trip button', (
    WidgetTester tester,
  ) async {
    await pumpHome(tester);

    // The destination field renders its placeholder and the request button is
    // the elevated action beneath the route info.
    expect(find.text('Where to?'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Request Trip'), findsOneWidget);
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

    await pumpHome(tester, pickup: pickupPlace, destination: destinationPlace);

    final line = drawnPolyline(tester);
    expect(line, isNotNull);
    expect(line!.color, Colors.blue);
    expect(line.pattern, const StrokePattern.solid());
    // The API's midpoint, not the client's straight line.
    expect(line.points, hasLength(3));
    expect(line.points[1], const LatLng(9.934, -84.095));
    expect(find.textContaining('Estimated '), findsNothing);
    expect(find.text('Retry'), findsNothing);
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
    },
  );

  testWidgets(
    'a 500 route response draws nothing and surfaces message + Retry',
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

      expect(
        drawnPolyline(tester),
        isNull,
        reason: 'an outage must not synthesize a straight line',
      );
      expect(find.text('failed to calculate route'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    },
  );

  testWidgets(
    'a 422 route response draws nothing and surfaces message + Retry',
    (WidgetTester tester) async {
      dioAdapter.onGet(
        ApiEndpoints.navigationRoute,
        (server) => server.reply(422, {
          'error': {
            'code': 'VALIDATION_ERROR',
            'message': 'invalid coordinates',
          },
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
    },
  );

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
      container.invalidate(
        multiLegRouteProvider(
          const RoutePlan(
            fromLat: 9.9281,
            fromLng: -84.0907,
            toLat: 9.94,
            toLng: -84.10,
          ),
        ),
      );
      await pumpRoute(tester);

      final after = drawnPolyline(tester);
      expect(after, isNotNull, reason: 'the previous road route is retained');
      expect(after!.color, Colors.blue);
      expect(
        after.points,
        hasLength(3),
        reason: 'never a two-point straight-line swap',
      );
      expect(after.points[1], const LatLng(9.934, -84.095));
      expect(find.text('Retry'), findsOneWidget);
      expect(find.textContaining('No road route is available'), findsOneWidget);
    },
  );

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

      // Before any stop: one pickup→destination leg.
      expect(drawnPolyline(tester)!.points, hasLength(3));

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
    },
  );

  testWidgets(
    'the waypoint trip POSTs the ordered stops for the fare estimate',
    (WidgetTester tester) async {
      dioAdapter.onGet(
        ApiEndpoints.navigationRoute,
        (server) => server.replyCallback(200, legRouteBody),
      );
      final estimateRequests = <Map<String, dynamic>>[];
      dioAdapter.onPost(
        ApiEndpoints.priceEstimate,
        (server) => server.replyCallback(200, (options) {
          estimateRequests.add(Map<String, dynamic>.from(options.data as Map));
          return {
            'estimates': [
              {
                'vehicle_type': 'sedan',
                'base_fare': 2.5,
                'distance_fare': 4.0,
                'time_fare': 1.1,
                'surge_multiplier': 1.0,
                'total': 8.5,
                'currency': 'USD',
                'demand_multiplier': 1.0,
                'supply_multiplier': 1.0,
                'grade_uplift_pct': 0.0,
                'is_estimate': false,
                'legs': [
                  {
                    'distance_m': 1650,
                    'duration_s': 150,
                    'distance_fare': 2.47,
                    'time_fare': 0.60,
                  },
                  {
                    'distance_m': 820,
                    'duration_s': 75,
                    'distance_fare': 1.24,
                    'time_fare': 0.30,
                  },
                ],
              },
            ],
          };
        }),
        data: {
          'pickup_lat': pickupPlace.lat,
          'pickup_lng': pickupPlace.lng,
          'dropoff_lat': destinationPlace.lat,
          'dropoff_lng': destinationPlace.lng,
          'stops': [
            {
              'lat': stopPlace.lat,
              'lng': stopPlace.lng,
              'address': stopPlace.address,
            },
          ],
        },
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

      // The API is waypoint-aware now, so the obsolete fare caveat is gone.
      expect(
        find.byKey(const ValueKey<String>('stops-fare-note')),
        findsNothing,
      );

      await tester.ensureVisible(find.text('Request Trip'));
      await tester.pump();
      await tester.tap(find.text('Request Trip'));
      await pumpRoute(tester);

      // The priced request carries the ordered stop, so the API — never the
      // client — prices the whole itinerary and the total is larger than the
      // pickup→destination-only request.
      expect(estimateRequests, hasLength(1));
      final request = estimateRequests.single;
      expect(request['pickup_lat'], pickupPlace.lat);
      expect(request['dropoff_lat'], destinationPlace.lat);
      expect(request['stops'], [
        {
          'lat': stopPlace.lat,
          'lng': stopPlace.lng,
          'address': stopPlace.address,
        },
      ]);
    },
  );

  // ---------------------------------------------------------------------------
  // [location] manual pickup fallback.
  // ---------------------------------------------------------------------------

  testWidgets('denied location shows the notice and opens the manual search', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.denied
      ..position = null;
    const manual = Place(
      id: 'manual',
      name: 'Manual Pickup',
      address: 'Somewhere Rd',
      lat: 9.95,
      lng: -84.05,
    );

    await pumpHome(tester, pickupResult: manual);

    expect(
      find.text(
        'Location is off. Enter a pickup location, or enable location.',
      ),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    // A plain denial has no settings deep-link.
    expect(find.text('Open settings'), findsNothing);

    // The pickup field always opens the search, even with no device fix.
    await tester.tap(find.text('Pickup location'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text('Manual Pickup'), findsOneWidget);
  });

  testWidgets('services off offers the location-settings action', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.servicesDisabled
      ..position = null;

    await pumpHome(tester);

    expect(find.text('Open location settings'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('a permanent denial offers the app-settings action', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.deniedPermanently
      ..position = null;

    await pumpHome(tester);

    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('a manual pickup drives the route leg and the fare estimate', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.granted
      ..position = testPosition(9.92, -84.08);
    const manual = Place(
      id: 'manual',
      name: 'Manual Pickup',
      address: 'Somewhere Rd',
      lat: 9.95,
      lng: -84.05,
    );

    final routeRequests = <Map<String, dynamic>>[];
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, (options) {
        routeRequests.add(Map<String, dynamic>.from(options.queryParameters));
        return legRouteBody(options);
      }),
    );
    final estimateRequests = <Map<String, dynamic>>[];
    dioAdapter.onPost(
      ApiEndpoints.priceEstimate,
      (server) => server.replyCallback(200, (options) {
        estimateRequests.add(Map<String, dynamic>.from(options.data as Map));
        return {
          'estimates': [
            {
              'vehicle_type': 'sedan',
              'base_fare': 2.5,
              'distance_fare': 4.0,
              'time_fare': 1.1,
              'surge_multiplier': 1.0,
              'total': 8.5,
              'currency': 'USD',
            },
          ],
        };
      }),
      data: {
        'pickup_lat': manual.lat,
        'pickup_lng': manual.lng,
        'dropoff_lat': destinationPlace.lat,
        'dropoff_lng': destinationPlace.lng,
      },
    );

    await pumpHome(tester, destination: destinationPlace, pickupResult: manual);

    // The device fix is the initial origin.
    expect(routeRequests.last['from_lat'], 9.92);

    // Choosing a place overrides it for the preview.
    await tester.tap(find.text('Current location'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await pumpRoute(tester);

    expect(find.text('Manual Pickup'), findsOneWidget);
    expect(routeRequests.last['from_lat'], manual.lat);
    expect(routeRequests.last['from_lng'], manual.lng);

    await tester.ensureVisible(find.text('Request Trip'));
    await tester.pump();
    await tester.tap(find.text('Request Trip'));
    await pumpRoute(tester);

    expect(estimateRequests, hasLength(1));
    expect(estimateRequests.single['pickup_lat'], manual.lat);
    expect(estimateRequests.single['pickup_lng'], manual.lng);
  });

  testWidgets('no device fix and no pickup fabricates nothing', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.denied
      ..position = null;
    var routeCalls = 0;
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, (_) {
        routeCalls++;
        return routeBody(estimate: false);
      }),
    );

    await pumpHome(tester, destination: destinationPlace);

    // A destination exists, but no origin: no route, no device marker, and the
    // search bias / default center is never treated as a pickup.
    expect(routeCalls, 0);
    expect(hasMarkerIcon(tester, Icons.my_location), isFalse);
    expect(find.text('Pickup location'), findsOneWidget);

    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Request Trip'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('Use current location clears the manual pickup', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.granted
      ..position = testPosition(9.92, -84.08);

    await pumpHome(tester, pickup: pickupPlace, destination: destinationPlace);

    expect(find.text('Pickup Point'), findsOneWidget);
    expect(find.text('Use current location'), findsOneWidget);

    await tester.tap(find.text('Use current location'));
    await pumpRoute(tester);

    expect(find.text('Current location'), findsOneWidget);
    expect(find.text('Pickup Point'), findsNothing);
    expect(find.text('Use current location'), findsNothing);
  });

  // ---------------------------------------------------------------------------
  // [trip] pickup recovery after a trip ends.
  // ---------------------------------------------------------------------------

  testWidgets('a cancelled trip restores the remembered pickup', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.denied
      ..position = null;
    const restored = Place(
      id: 'restored',
      name: 'Restored Pickup',
      address: 'Old Rd',
      lat: 9.9281,
      lng: -84.0907,
    );
    container.read(pickupMemoryProvider.notifier)
      ..remember(restored)
      ..markReturning(restorePickup: true);

    await pumpHome(tester);

    expect(find.text('Restored Pickup'), findsOneWidget);
    // The pending intent is consumed exactly once.
    expect(container.read(pickupMemoryProvider).restoreOnHome, isNull);
  });

  testWidgets('a completed trip does not restore and clears the pickup', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.denied
      ..position = null;
    const restored = Place(
      id: 'restored',
      name: 'Restored Pickup',
      address: 'Old Rd',
      lat: 9.96,
      lng: -84.02,
    );
    container.read(pickupMemoryProvider.notifier)
      ..remember(restored)
      ..markReturning(restorePickup: false);

    await pumpHome(tester);

    expect(find.text('Restored Pickup'), findsNothing);
    expect(find.text('Pickup location'), findsOneWidget);
    expect(container.read(pickupMemoryProvider).manualPickup, isNull);
    expect(container.read(pickupMemoryProvider).restoreOnHome, isNull);
  });

  testWidgets('the constructor pickupMemory override drives a restore', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.granted
      ..position = null;
    const restored = Place(
      id: 'ctor',
      name: 'Ctor Pickup',
      address: 'Old Rd',
      lat: 9.9281,
      lng: -84.0907,
    );

    await pumpHome(
      tester,
      pickupMemory: const PickupMemory(
        manualPickup: restored,
        restoreOnHome: true,
      ),
    );

    expect(find.text('Ctor Pickup'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  // ---------------------------------------------------------------------------
  // Bug #19 — the widget-coverage holes the [location]/[trip] plans recorded.
  // ---------------------------------------------------------------------------

  testWidgets(
    'the permanent-denial Open settings action dispatches to the service',
    (WidgetTester tester) async {
      fakeLocation
        ..availability = LocationAvailability.deniedPermanently
        ..position = null;

      await pumpHome(tester);

      expect(find.text('Open settings'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await tester.pump();

      expect(fakeLocation.openAppSettingsCalls, 1);
      expect(fakeLocation.openLocationSettingsCalls, 0);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the services-off action dispatches to the location-settings service',
    (WidgetTester tester) async {
      fakeLocation
        ..availability = LocationAvailability.servicesDisabled
        ..position = null;

      await pumpHome(tester);

      expect(find.text('Open location settings'), findsOneWidget);
      await tester.tap(find.text('Open location settings'));
      await tester.pump();

      expect(fakeLocation.openLocationSettingsCalls, 1);
      expect(fakeLocation.openAppSettingsCalls, 0);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a restored pickup drives the route leg with its own coordinates', (
    WidgetTester tester,
  ) async {
    // The restore path re-fits the camera, which makes flutter_map fetch tiles;
    // under `flutter_test` every HTTP request answers 400, so the image codec
    // reports a load failure. Those are unrelated to the route/estimate
    // contract this test pins, so they are filtered out.
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.library == 'image resource service') return;
      originalOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = originalOnError);

    fakeLocation
      ..availability = LocationAvailability.denied
      ..position = null;
    const restored = Place(
      id: 'restored',
      name: 'Restored Pickup',
      address: 'Old Rd',
      lat: 9.95,
      lng: -84.05,
    );
    final routeRequests = <Map<String, dynamic>>[];
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, (options) {
        routeRequests.add(Map<String, dynamic>.from(options.queryParameters));
        return legRouteBody(options);
      }),
    );
    final estimateRequests = <Map<String, dynamic>>[];
    dioAdapter.onPost(
      ApiEndpoints.priceEstimate,
      (server) => server.replyCallback(200, (options) {
        estimateRequests.add(Map<String, dynamic>.from(options.data as Map));
        return {
          'estimates': [
            {
              'vehicle_type': 'sedan',
              'base_fare': 2.5,
              'total': 8.5,
              'currency': 'USD',
            },
          ],
        };
      }),
      data: Matchers.any,
    );

    await pumpHome(
      tester,
      destination: destinationPlace,
      pickupMemory: const PickupMemory(
        manualPickup: restored,
        restoreOnHome: true,
      ),
    );

    // The restored name is shown AND the route leg starts at the restored
    // pickup's coordinates — not the device fix or the destination.
    expect(find.text('Restored Pickup'), findsOneWidget);
    expect(routeRequests, isNotEmpty);
    expect(routeRequests.last['from_lat'], restored.lat);
    expect(routeRequests.last['from_lng'], restored.lng);

    await tester.ensureVisible(find.text('Request Trip'));
    await tester.pump();
    await tester.tap(find.text('Request Trip'));
    await pumpRoute(tester);

    expect(estimateRequests, hasLength(1));
    expect(estimateRequests.single['pickup_lat'], restored.lat);
    expect(estimateRequests.single['pickup_lng'], restored.lng);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('booking a trip remembers the pickup used (remember call-site)', (
    WidgetTester tester,
  ) async {
    fakeLocation
      ..availability = LocationAvailability.granted
      ..position = testPosition(9.92, -84.08);
    const manual = Place(
      id: 'manual',
      name: 'Manual Pickup',
      address: 'Somewhere Rd',
      lat: 9.95,
      lng: -84.05,
    );
    dioAdapter.onGet(
      ApiEndpoints.navigationRoute,
      (server) => server.replyCallback(200, legRouteBody),
    );
    dioAdapter.onPost(
      ApiEndpoints.priceEstimate,
      (server) => server.reply(200, {
        'estimates': [
          {
            'vehicle_type': 'sedan',
            'base_fare': 2.5,
            'total': 8.5,
            'currency': 'USD',
          },
        ],
      }),
      data: Matchers.any,
    );
    dioAdapter.onPost(
      ApiEndpoints.rides,
      (server) => server.reply(200, {
        'ride': {'id': 'ride-42', 'status': 'pending'},
      }),
      data: Matchers.any,
    );

    await pumpHome(tester, destination: destinationPlace, pickupResult: manual);

    // Choose the manual pickup, replacing the device fix.
    await tester.tap(find.text('Current location'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await pumpRoute(tester);
    expect(find.text('Manual Pickup'), findsOneWidget);
    expect(container.read(pickupMemoryProvider).manualPickup, isNull);

    // Complete the booking: the fare sheet's Confirm triggers `_createRide`,
    // which is the `remember(_pickupLocation)` call-site.
    await tester.ensureVisible(find.text('Request Trip'));
    await tester.pump();
    await tester.tap(find.text('Request Trip'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm Ride'));
    await tester.pumpAndSettle();

    expect(container.read(pickupMemoryProvider).manualPickup?.id, manual.id);

    await tester.pumpWidget(const SizedBox());
  });

  // ---------------------------------------------------------------------------
  // Bug #20 — destination/stop search with neither a device fix nor a manual
  // pickup. The `_searchBias()` center biases the request only; it is never
  // written into `_pickupLocation`/`_destination` or the booking.
  // ---------------------------------------------------------------------------

  testWidgets(
    'no fix and no pickup: the destination field opens the search with a bias',
    (WidgetTester tester) async {
      fakeLocation
        ..availability = LocationAvailability.denied
        ..position = null;
      final pushes = <Map<String, dynamic>>[];

      await pumpHome(
        tester,
        destinationResult: destinationPlace,
        searchPushes: pushes,
      );

      // The field starts empty and the old blocking guard's snackbar is gone.
      expect(find.text('Where to?'), findsOneWidget);
      expect(find.text('Could not determine your location'), findsNothing);

      await tester.tap(find.text('Where to?'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // The search opened (not the old early-return) with a non-null bias, and
      // the picked place landed in the destination field.
      expect(pushes, hasLength(1));
      expect(pushes.single['hint'], 'Enter destination');
      expect(pushes.single['lat'], isNotNull);
      expect(pushes.single['lng'], isNotNull);
      expect(find.text('Dropoff Point'), findsOneWidget);

      // The bias is a search center only: no pickup was fabricated, so the
      // booking action stays disabled.
      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Request Trip'),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'no fix and no pickup: adding a stop opens the search with a bias',
    (WidgetTester tester) async {
      fakeLocation
        ..availability = LocationAvailability.denied
        ..position = null;
      final pushes = <Map<String, dynamic>>[];

      // A destination alone exposes the stop editor, even with no origin.
      await pumpHome(
        tester,
        destination: destinationPlace,
        addStopResult: stopPlace,
        searchPushes: pushes,
      );

      expect(
        find.byKey(const ValueKey<String>('add-stop-button')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey<String>('add-stop-button')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // The stop search opened with a real bias and the picked stop landed in
      // the itinerary.
      expect(pushes, hasLength(1));
      expect(pushes.single['hint'], 'Add a stop');
      expect(pushes.single['lat'], isNotNull);
      expect(pushes.single['lng'], isNotNull);
      expect(find.text('Coffee Shop'), findsOneWidget);
    },
  );

  testWidgets(
    'selecting a destination with a device fix drives the route and estimate',
    (WidgetTester tester) async {
      fakeLocation
        ..availability = LocationAvailability.granted
        ..position = testPosition(9.92, -84.08);
      final routeRequests = <Map<String, dynamic>>[];
      dioAdapter.onGet(
        ApiEndpoints.navigationRoute,
        (server) => server.replyCallback(200, (options) {
          routeRequests.add(Map<String, dynamic>.from(options.queryParameters));
          return legRouteBody(options);
        }),
      );
      final estimateRequests = <Map<String, dynamic>>[];
      dioAdapter.onPost(
        ApiEndpoints.priceEstimate,
        (server) => server.replyCallback(200, (options) {
          estimateRequests.add(Map<String, dynamic>.from(options.data as Map));
          return {
            'estimates': [
              {
                'vehicle_type': 'sedan',
                'base_fare': 2.5,
                'total': 8.5,
                'currency': 'USD',
              },
            ],
          };
        }),
        data: Matchers.any,
      );

      await pumpHome(tester, destinationResult: destinationPlace);

      await tester.tap(find.text('Where to?'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await pumpRoute(tester);

      // The picked destination is set and the preview leg ends at its coords.
      expect(find.text('Dropoff Point'), findsOneWidget);
      expect(routeRequests, isNotEmpty);
      expect(routeRequests.last['to_lat'], destinationPlace.lat);
      expect(routeRequests.last['to_lng'], destinationPlace.lng);

      await tester.ensureVisible(find.text('Request Trip'));
      await tester.pump();
      await tester.tap(find.text('Request Trip'));
      await pumpRoute(tester);

      expect(estimateRequests, hasLength(1));
      expect(estimateRequests.single['dropoff_lat'], destinationPlace.lat);
      expect(estimateRequests.single['dropoff_lng'], destinationPlace.lng);
    },
  );

  // ---------------------------------------------------------------------------
  // [home] resizable bottom panel (drag + scroll).
  // ---------------------------------------------------------------------------

  // A shorter surface than the tall default so the content-driven max is
  // actually above the initial 0.25 and the panel has room to grow.
  const resizeSurface = Size(800, 600);

  DraggableScrollableSheet sheetWidget(WidgetTester tester) => tester
      .widget<DraggableScrollableSheet>(find.byType(DraggableScrollableSheet));

  /// The sheet's current size as a fraction of the viewport.
  double sheetSize(WidgetTester tester) => tester
      .widget<FractionallySizedBox>(
        find.descendant(
          of: find.byType(DraggableScrollableSheet),
          matching: find.byType(FractionallySizedBox),
        ),
      )
      .heightFactor!;

  double mapHeight(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey<String>('home-map'))).height;

  /// Drags the panel grab handle with the given device kind. The mouse is the
  /// desktop/web path under test; touch stays on the existing scroll path.
  Future<void> dragHandle(
    WidgetTester tester,
    Offset offset, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) => tester.drag(
    find.byKey(const ValueKey<String>('home-sheet-handle')),
    offset,
    kind: kind,
  );

  testWidgets(
    'scrolling the panel up reaches the content-driven max and shrinks the map',
    (WidgetTester tester) async {
      await pumpHome(
        tester,
        pickup: pickupPlace,
        destination: destinationPlace,
        surface: resizeSurface,
      );

      final sheet = sheetWidget(tester);
      expect(sheet.snap, isTrue);
      expect(sheet.maxChildSize, greaterThan(sheet.initialChildSize));
      expect(sheet.minChildSize, lessThan(sheet.initialChildSize));
      expect(sheetSize(tester), closeTo(sheet.initialChildSize, 0.001));

      final beforeMap = mapHeight(tester);
      expect(beforeMap, closeTo(600 * (1 - sheet.initialChildSize), 1));

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();

      final maxSheet = sheetWidget(tester).maxChildSize;
      expect(sheetSize(tester), closeTo(maxSheet, 0.01));
      expect(mapHeight(tester), lessThan(beforeMap));
      expect(mapHeight(tester), closeTo(600 * (1 - maxSheet), 2));
    },
  );

  testWidgets(
    'scrolling the panel down reaches handle-only min and lifts the FAB',
    (WidgetTester tester) async {
      await pumpHome(
        tester,
        pickup: pickupPlace,
        destination: destinationPlace,
        surface: resizeSurface,
      );

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, 600),
      );
      await tester.pumpAndSettle();

      final minSheet = sheetWidget(tester).minChildSize;
      expect(sheetSize(tester), closeTo(minSheet, 0.01));
      expect(mapHeight(tester), closeTo(600 * (1 - minSheet), 2));

      // The my-location control rides above the collapsed panel: its bottom edge
      // never dips below the panel's top.
      final fab = tester.getRect(find.byType(FloatingActionButton));
      final panel = tester.getRect(find.byType(AppBottomSheet));
      expect(fab.bottom, lessThanOrEqualTo(panel.top));
    },
  );

  testWidgets('a released drag snaps to the nearest snap point', (
    WidgetTester tester,
  ) async {
    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );
    final sheet = sheetWidget(tester);

    // A small upward drag with no velocity settles back to `initial` (the
    // offset clears the touch slop so it is a scroll, not a tap on a field).
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -40));
    await tester.pumpAndSettle();
    expect(sheetSize(tester), closeTo(sheet.initialChildSize, 0.01));

    // A drag well past the midpoint snaps up to the content-driven max.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    final maxSheet = sheetWidget(tester).maxChildSize;
    expect(sheetSize(tester), closeTo(maxSheet, 0.01));
  });

  testWidgets('the keyboard inset pads the sheet without collapsing it', (
    WidgetTester tester,
  ) async {
    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );
    final before = sheetSize(tester);

    tester.view.viewInsets = const FakeViewPadding(bottom: 200);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump();

    // A focused field being lifted does not shrink the panel.
    expect(sheetSize(tester), closeTo(before, 0.01));
    await tester.ensureVisible(find.text('Request Trip'));
    await tester.pump();
    expect(find.text('Request Trip'), findsOneWidget);
  });

  testWidgets('the handle toggles the panel between min and opening size', (
    WidgetTester tester,
  ) async {
    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    Semantics handle() => tester
        .widgetList<Semantics>(find.byType(Semantics))
        .firstWhere(
          (widget) => widget.properties.label == 'Drag to resize booking panel',
        );

    final sheet = sheetWidget(tester);
    expect(handle().properties.onTap, isNotNull);
    expect(handle().properties.value, 'Expanded');
    expect(sheetSize(tester), closeTo(sheet.initialChildSize, 0.001));

    // Invoking the handle's accessible action collapses the panel to its
    // handle-only minimum.
    handle().properties.onTap!();
    await tester.pumpAndSettle();
    expect(handle().properties.value, 'Collapsed');
    expect(sheetSize(tester), closeTo(sheet.minChildSize, 0.01));

    // Invoking it again expands back to the opening size.
    handle().properties.onTap!();
    await tester.pumpAndSettle();
    expect(handle().properties.value, 'Expanded');
    expect(sheetSize(tester), closeTo(sheet.initialChildSize, 0.01));
  });

  testWidgets('a mouse drag up on the handle reaches max and shrinks the map', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    final sheet = sheetWidget(tester);
    expect(sheetSize(tester), closeTo(sheet.initialChildSize, 0.001));
    final beforeMap = mapHeight(tester);
    expect(beforeMap, closeTo(600 * (1 - sheet.initialChildSize), 1));

    await dragHandle(
      tester,
      const Offset(0, -600),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(sheetSize(tester), closeTo(sheet.maxChildSize, 0.01));
    expect(mapHeight(tester), lessThan(beforeMap));
    expect(mapHeight(tester), closeTo(600 * (1 - sheet.maxChildSize), 2));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'a mouse drag down from max on the handle reaches min and lifts the FAB',
    (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await pumpHome(
        tester,
        pickup: pickupPlace,
        destination: destinationPlace,
        surface: resizeSurface,
      );

      await dragHandle(
        tester,
        const Offset(0, -600),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final maxSheet = sheetWidget(tester).maxChildSize;
      expect(sheetSize(tester), closeTo(maxSheet, 0.01));

      await dragHandle(
        tester,
        const Offset(0, 600),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();

      final minSheet = sheetWidget(tester).minChildSize;
      expect(sheetSize(tester), closeTo(minSheet, 0.01));
      expect(mapHeight(tester), closeTo(600 * (1 - minSheet), 2));

      // The my-location control rides above the collapsed panel: its bottom edge
      // never dips below the panel's top.
      final fab = tester.getRect(find.byType(FloatingActionButton));
      final panel = tester.getRect(find.byType(AppBottomSheet));
      expect(fab.bottom, lessThanOrEqualTo(panel.top));
      debugDefaultTargetPlatformOverride = null;
    },
  );

  // D5 no-trackpad-competition invariant: the handle's drag recognizer is
  // mouse-only. Trackpad drags stay with the sheet's scrollable, so deleting
  // `supportedDevices` must fail here rather than silently re-introducing two
  // competing recognizers.
  testWidgets('the sheet handle only accepts mouse pointers', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    final handle = tester.widget<GestureDetector>(
      find.byKey(const ValueKey<String>('home-sheet-handle')),
    );
    expect(handle.supportedDevices, const <PointerDeviceKind>{
      PointerDeviceKind.mouse,
    });
    // The mouse path is active on desktop, so the recognizer exists to filter.
    expect(handle.onVerticalDragStart, isNotNull);
    expect(handle.onVerticalDragCancel, isNotNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a cancelled handle drag settles on a snap point', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    final sheet = sheetWidget(tester);
    final snaps = <double>[
      sheet.minChildSize,
      sheet.initialChildSize,
      sheet.maxChildSize,
    ];
    final initial = sheet.initialChildSize;

    // Grow the panel mid-drag, then cancel the pointer as if it left the
    // window. Flutter delivers a post-threshold cancel through the drag-end
    // callback, so this pins that a cancelled pointer still settles on a snap
    // instead of leaving the panel stranded between snap points.
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('home-sheet-handle'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(sheetSize(tester), greaterThan(initial));

    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final settled = sheetSize(tester);
    expect(
      snaps.any((snap) => (settled - snap).abs() < 0.01),
      isTrue,
      reason: 'a cancelled drag settled at $settled, not a snap point $snaps',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  // The pointer-cancel callback itself: once the drag has been accepted,
  // Flutter reports a `PointerCancelEvent` as the drag-end callback, so the
  // `onVerticalDragCancel` branch it guards can be reached only by invoking it
  // directly. It must run the same settle and must not throw.
  testWidgets('the drag-cancel callback settles a live drag on a snap point', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    final sheet = sheetWidget(tester);
    final snaps = <double>[
      sheet.minChildSize,
      sheet.initialChildSize,
      sheet.maxChildSize,
    ];
    final initial = sheet.initialChildSize;
    final handleFinder = find.byKey(
      const ValueKey<String>('home-sheet-handle'),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(handleFinder),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(sheetSize(tester), greaterThan(initial));

    final cancel = tester
        .widget<GestureDetector>(handleFinder)
        .onVerticalDragCancel;
    expect(cancel, isNotNull);
    cancel!();
    await gesture.cancel();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final settled = sheetSize(tester);
    expect(
      snaps.any((snap) => (settled - snap).abs() < 0.01),
      isTrue,
      reason: 'a cancelled drag settled at $settled, not a snap point $snaps',
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a mouse fling up snaps up and a fling down snaps down', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    final sheet = sheetWidget(tester);
    final initial = sheet.initialChildSize;
    final min = sheet.minChildSize;
    final max = sheet.maxChildSize;
    final handle = find.byKey(const ValueKey<String>('home-sheet-handle'));

    // An upward fling from the opening size lands on the next snap above it.
    await tester.flingFrom(
      tester.getCenter(handle),
      const Offset(0, -100),
      1000,
      deviceKind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sheetSize(tester), closeTo(max, 0.01));

    // A downward fling from max lands on the next snap below it.
    await tester.flingFrom(
      tester.getCenter(handle),
      const Offset(0, 100),
      1000,
      deviceKind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sheetSize(tester), closeTo(initial, 0.01));

    // A downward fling from the opening size reaches the handle-only minimum.
    await tester.flingFrom(
      tester.getCenter(handle),
      const Offset(0, 100),
      1000,
      deviceKind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sheetSize(tester), closeTo(min, 0.01));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the mouse grabber is inert on Android and touch still resizes', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pumpHome(
      tester,
      pickup: pickupPlace,
      destination: destinationPlace,
      surface: resizeSurface,
    );

    expect(
      shouldEnableSheetDragHandle(
        isWeb: false,
        platform: TargetPlatform.android,
      ),
      isFalse,
    );

    final handle = tester.widget<GestureDetector>(
      find.byKey(const ValueKey<String>('home-sheet-handle')),
    );
    expect(handle.onVerticalDragStart, isNull);
    expect(handle.onVerticalDragUpdate, isNull);
    expect(handle.onVerticalDragEnd, isNull);
    expect(handle.onVerticalDragCancel, isNull);

    final before = sheetSize(tester);

    // A mouse drag cannot start a recognizer on mobile.
    await dragHandle(
      tester,
      const Offset(0, -600),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(sheetSize(tester), closeTo(before, 0.001));

    // Touch still drives the existing scroll path.
    await dragHandle(tester, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(sheetSize(tester), closeTo(sheetWidget(tester).maxChildSize, 0.01));
    debugDefaultTargetPlatformOverride = null;
  });
}
