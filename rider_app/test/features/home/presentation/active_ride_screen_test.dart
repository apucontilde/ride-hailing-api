import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:latlong2/latlong.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/driver_tracking_provider.dart';
import 'package:rider_app/features/home/data/location_ping_service.dart';
import 'package:rider_app/features/home/data/pickup_memory_provider.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';
import 'package:rider_app/features/home/data/trip_route_provider.dart';
import 'package:rider_app/features/home/model/driver.dart';
import 'package:rider_app/features/home/model/place.dart';
import 'package:rider_app/features/home/presentation/active_ride_screen.dart';
import 'package:rider_app/features/home/presentation/location_search_screen.dart';

import '../../../support/fake_websocket_service.dart';

/// Records only the lifecycle the screen drives; the real throttled stream and
/// its geolocator platform channel are exercised in the service unit tests.
class FakeLocationPingService extends LocationPingService {
  FakeLocationPingService(super.apiClient);

  int startCount = 0;
  int stopCount = 0;
  bool _active = false;

  @override
  void start() {
    startCount++;
    _active = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _active = false;
  }

  @override
  bool get isActive => _active;
}

Map<String, dynamic> acceptedEvent({
  String rideId = 'ride-1',
  String driverId = 'driver-1',
  double rating = 4.9,
  int etaSeconds = 300,
  bool includePickup = true,
}) => {
  'type': 'ride.updated',
  'data': {
    'ride_id': rideId,
    'status': 'accepted',
    'eta_seconds': etaSeconds,
    'driver': {
      'id': driverId,
      'first_name': 'Maria',
      'photo_url': 'https://example.com/maria.jpg',
      'rating': rating,
      'vehicle': {
        'make': 'Toyota',
        'model': 'Corolla',
        'color': 'White',
        'plate_number': 'AB123CD',
      },
      'location': {'lat': 9.93, 'lng': -84.09, 'heading': 90},
    },
    if (includePickup)
      'pickup': {'lat': 9.9281, 'lng': -84.0907, 'address': 'Main St'},
    'dropoff': {'lat': 9.94, 'lng': -84.10, 'address': 'Airport Rd'},
  },
};

/// `GET /rides/{id}` body (`internal/model/ride.go`).
Map<String, dynamic> rideJson({
  String id = 'ride-1',
  String status = 'accepted',
  double total = 2870.5,
  double dropoffLat = 9.94,
  double dropoffLng = -84.1,
}) {
  return {
    'id': id,
    'rider_id': 'rider-1',
    'driver_id': 'driver-1',
    'status': status,
    'pickup_lat': 9.9281,
    'pickup_lng': -84.0907,
    'dropoff_lat': dropoffLat,
    'dropoff_lng': dropoffLng,
    'pickup_address': 'Main St',
    'dropoff_address': 'Airport Rd',
    'vehicle_type': 'sedan',
    'base_fare': 1200.0,
    'distance_fare': 900.0,
    'time_fare': 700.0,
    'surge_multiplier': 1.1,
    'total_fare': total,
    'requested_at': '2026-03-01T10:00:00Z',
    'accepted_at': '2026-03-01T10:02:00Z',
    'created_at': '2026-03-01T10:00:00Z',
    'updated_at': '2026-03-01T10:05:00Z',
  };
}

/// How the mocked `GET /navigation/route` should answer.
enum RouteMock { road, estimate, http422, http500 }

/// A road-shaped answer that reflects the requested leg, so the concatenation
/// of the itinerary is visible.
Map<String, dynamic> routeBody(
  RequestOptions options, {
  required bool estimate,
}) {
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
    'is_estimate': estimate,
  };
}

/// `GET /rides/{id}/receipt` body.
Map<String, dynamic> receiptJson({double total = 2800.0}) => {
  'receipt': {
    'base_fare': 1200.0,
    'distance_fare': 900.0,
    'time_fare': 700.0,
    'surge_multiplier': 1.25,
    'total': total,
  },
};

/// The `driver.location` WS event shape (`tests/ride_lifecycle_test.go`).
Map<String, dynamic> driverLocationEvent(double lat, double lng) => {
  'type': 'driver.location',
  'data': {
    'ride_id': 'ride-1',
    'driver_id': 'driver-1',
    'lat': lat,
    'lng': lng,
    'heading': 45,
    'speed': 12.5,
  },
};

/// The default `POST /estimates/price` row used by the change-destination
/// confirmation (the booked `sedan`).
const Map<String, dynamic> _defaultEstimate = {
  'vehicle_type': 'sedan',
  'base_fare': 1.0,
  'distance_fare': 2.0,
  'time_fare': 1.0,
  'surge_multiplier': 1.0,
  'total': 4.0,
  'currency': '\$',
  'is_estimate': false,
  'legs': [
    {'distance_m': 1500, 'duration_s': 240, 'distance_fare': 2.0, 'time_fare': 1.0},
  ],
};

void main() {
  late FakeWebSocketService ws;
  late RideStatusNotifier rideNotifier;
  late ApiClient apiClient;
  late DioAdapter dioAdapter;

  /// Captured from the `driverTrackingProvider` override so a test can read the
  /// real notifier's poll counters and `isPolling`.
  late DriverTrackingNotifier tracker;

  /// Captured from the `tripRouteProvider` override so a test can assert the
  /// refresh tick is stopped.
  late TripRouteNotifier tripRoute;

  /// The mutable `GET /rides/{id}` answer, so a destination change is just a
  /// reassignment before the `ride.updated` that triggers the re-request.
  late Map<String, dynamic> rideResponse;

  /// Every `GET /navigation/route` query, in order, to prove re-requests.
  late List<Map<String, dynamic>> routeRequests;

  /// The scope the screen runs in, so a test can read the pickup-return intent.
  late ProviderContainer container;

  /// Built **inside** each test body, not in `setUp`, and that is load-bearing:
  /// a broadcast `StreamController` captures `Zone.current` at `listen()`, and
  /// `RideStatusNotifier` subscribes in its constructor. Created from `setUp`
  /// (outside the test's fake-async zone) the delivery — and every `await`
  /// continuation the screen starts from a WS event — lands on the real
  /// microtask queue, which `tester.pump()` does not flush: the completion
  /// dialogs would then only appear after the test body had already returned.
  void fixture({
    RouteMock route = RouteMock.road,
    List<Map<String, dynamic>>? stops,
    Map<String, dynamic>? etaReply,
    List<Map<String, dynamic>>? estimates,
    int estimateStatus = 200,
  }) {
    ws = FakeWebSocketService();
    rideNotifier = RideStatusNotifier(ws);
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
    routeRequests = [];
    rideResponse = {'ride': rideJson(), 'stops': stops ?? <dynamic>[]};
    // Every screen entry path resolves the ride id and pulls the authoritative
    // ride, and seeds the already-rated set; both are real requests, so both are
    // mocked here rather than left to fail with a pending timer. The addendum
    // re-reads the same ride for the trip route, so the answer is a callback.
    dioAdapter.onGet(
      '/api/v1/rides/ride-1',
      (server) => server.replyCallback(200, (_) => rideResponse),
    );
    dioAdapter.onGet(
      '/api/v1/rider/ratings',
      (server) => server.reply(200, {
        'ratings': <dynamic>[],
        'total': 0,
        'page': 1,
        'per_page': 50,
        'total_pages': 0,
      }),
    );
    // `[ontrip]` R1: the client ETA compute. The default answers the `300`
    // placeholder so it never overwrites the accept-time value (and the two
    // existing ETA-honesty assertions stay meaningful); a test that wants a
    // fresh live number passes `etaReply`.
    dioAdapter.onGet(
      '/api/v1/geo/eta',
      (server) => server.reply(
        200,
        etaReply ??
            {'eta_seconds': 300, 'distance_meters': 0, 'is_estimate': false},
      ),
    );
    // `[ontrip]` R-1: the change-destination confirmation estimate.
    dioAdapter.onPost(
      '/api/v1/estimates/price',
      (server) => server.reply(
        estimateStatus,
        estimateStatus == 200
            ? {'estimates': estimates ?? [_defaultEstimate]}
            : {
                'error': {
                  'code': 'INTERNAL',
                  'message': 'failed to price route',
                },
              },
      ),
      data: Matchers.any,
    );
    dioAdapter.onGet('/api/v1/navigation/route', (server) {
      final status = switch (route) {
        RouteMock.http422 => 422,
        RouteMock.http500 => 500,
        RouteMock.road || RouteMock.estimate => 200,
      };
      return server.replyCallback(status, (options) {
        routeRequests.add(Map<String, dynamic>.from(options.queryParameters));
        return switch (route) {
          RouteMock.road => routeBody(options, estimate: false),
          RouteMock.estimate => routeBody(options, estimate: true),
          RouteMock.http422 => {
            'error': {
              'code': 'VALIDATION_ERROR',
              'message': 'invalid coordinates',
            },
          },
          RouteMock.http500 => {
            'error': {
              'code': 'INTERNAL',
              'message': 'failed to calculate route',
            },
          },
        };
      });
    });
  }

  tearDown(() {
    ws.disposeController();
    // `rideNotifier` is handed to `rideStatusProvider.overrideWith`, so Riverpod
    // owns its disposal when the test's `ProviderScope` is torn down.
  });

  void emit(Map<String, dynamic> event) => ws.emit(event);

  Widget buildRouter({
    FakeLocationPingService? ping,
    Duration routeRefreshInterval = const Duration(seconds: 30),
    Place? changeDestinationResult,
    List<Map<String, dynamic>>? searchExtras,
    Future<LatLng?> Function()? riderFix,
  }) {
    final router = GoRouter(
      initialLocation: '/active-ride',
      routes: [
        GoRoute(
          path: '/active-ride',
          builder: (context, state) => const ActiveRideScreen(),
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Home'),
                  // Lets a test start a second trip on the same session-scoped
                  // providers, which is what the FIX-C regression needs.
                  ElevatedButton(
                    onPressed: () => context.go('/active-ride'),
                    child: const Text('Start next ride'),
                  ),
                ],
              ),
            ),
          ),
        ),
        // The destination-change round trip: production routes this to the real
        // search screen, so the **real** `LocationSearchScreen` is mounted with
        // the pushed bias. The screen still records the pushed bias `extra` and
        // pops a fixed `Place`, so the push contract (a non-null center) stays
        // under test. The screen's own blocking branch is covered by the
        // negative-control pair in `location_search_screen_test.dart`.
        if (changeDestinationResult != null || searchExtras != null)
          GoRoute(
            path: '/location-search',
            builder: (_, state) {
              final extra =
                  (state.extra as Map?)?.cast<String, dynamic>() ?? {};
              searchExtras?.add(extra);
              return Builder(
                builder: (context) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (context.mounted && changeDestinationResult != null) {
                      context.pop<Place>(changeDestinationResult);
                    }
                  });
                  return LocationSearchScreen(
                    hint: extra['hint'] as String? ?? 'Search destinations...',
                    lat: extra['lat'] as double?,
                    lng: extra['lng'] as double?,
                  );
                },
              );
            },
          ),
      ],
    );
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(apiClient),
        // No tiles: the map must not touch the network under flutter_test.
        mapTileLayerProvider.overrideWith((ref, config) => null),
        rideStatusProvider.overrideWith((ref) => rideNotifier),
        driverTrackingProvider.overrideWith((ref) {
          // Production durations (5 s tick, 10 s silence window) so the test
          // asserts the real schedule; `tester.pump` is what elapses them.
          return tracker = DriverTrackingNotifier(apiClient, ref);
        }),
        tripRouteProvider.overrideWith((ref) {
          return tripRoute = TripRouteNotifier(
            apiClient,
            refreshInterval: routeRefreshInterval,
          );
        }),
        if (ping != null) locationPingServiceProvider.overrideWithValue(ping),
        if (riderFix != null)
          riderCurrentPositionProvider.overrideWithValue(riderFix),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// The first trip polyline the screen is drawing, or null when it is drawing
  /// none (the honest no-geometry error state).
  Polyline? tripPolyline(WidgetTester tester) {
    final layer = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
    return layer.polylines.isEmpty ? null : layer.polylines.first;
  }

  /// The live camera of the mounted `FlutterMap`.
  MapCamera mapCamera(WidgetTester tester) =>
      tester.widget<FlutterMap>(find.byType(FlutterMap)).mapController!.camera;

  /// The shared locate button.
  Finder locateButton() => find.byKey(const Key('map-locate-button'));

  /// A `ride.updated` status transition (the WS event shape).
  Map<String, dynamic> statusEvent(String backendStatus) => {
    'type': 'ride.updated',
    'data': {'ride_id': 'ride-1', 'status': backendStatus},
  };

  /// Let the trip route's `GET /rides/:id` → `GET /navigation/route` chain
  /// resolve. Small positive pumps fire Dio's zero-duration response timer but
  /// stay far short of the 30 s refresh tick.
  Future<void> pumpRoute(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  /// Let an event emitted after the tree is mounted reach the screen.
  ///
  /// A broadcast `StreamController` created in `setUp` schedules its delivery
  /// outside the test's fake-async zone, so the first `pump` returns before the
  /// state change lands and the second one draws it. `pumpAndSettle` is the
  /// alternative where no `Timer.periodic` or `SnackBar` is in play.
  Future<void> emitAndSettle(
    WidgetTester tester,
    Map<String, dynamic> event, {
    bool settle = false,
  }) async {
    emit(event);
    if (settle) {
      await tester.pumpAndSettle();
      return;
    }
    await tester.pump();
    await tester.pump();
  }

  /// Tear the tree down and let the entry-path requests settle. Disposing is not
  /// cosmetic: the screen's 5 s tracking tick is a live `Timer.periodic`, and a
  /// test that leaves one armed fails the framework's pending-timer check.
  Future<void> settleAndDispose(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    // Dio schedules a zero-duration timer per request; the tree swap can leave
    // one in flight.
    await tester.pump();
  }

  /// The point of the driver marker in the `MarkerLayer`, or null when the
  /// screen has no typed `driverLocation` to draw.
  LatLng? driverMarkerPoint(WidgetTester tester) {
    final layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    for (final marker in layer.markers) {
      final child = marker.child;
      if (child is Icon && child.icon == Icons.directions_car) {
        return marker.point;
      }
    }
    return null;
  }

  testWidgets('accepting a ride shows the active ride screen', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    expect(find.text('Cancel Ride'), findsOneWidget);
    expect(find.text('Driver Approaching'), findsOneWidget);
    // LC-4 item 5: the typed `driver` block, not invented `driver_name` /
    // `car_model` keys.
    expect(find.text('Maria'), findsOneWidget);
    expect(find.text('White Toyota Corolla · AB123CD'), findsOneWidget);
    expect(find.text('★ 4.9'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('a driver with no ratings reads as New driver', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent(rating: 0.0));

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    expect(find.text('★ New driver'), findsOneWidget);
    expect(find.text('★ 0.0'), findsNothing);

    await settleAndDispose(tester);
  });

  testWidgets(
    'pressed cancel shows confirmation and posts the cancel request',
    (WidgetTester tester) async {
      fixture();
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.reply(200, {
          'ride': {'id': 'ride-1', 'status': 'cancelled'},
        }),
      );
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      await tester.tap(find.text('Cancel Ride'));
      await tester.pump();

      expect(find.text('Cancel this ride?'), findsOneWidget);

      await tester.tap(find.text('Yes, Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(find.text('Ride cancelled successfully'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);
      // A cancel keeps the pickup so the rider can retry immediately.
      expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

      await settleAndDispose(tester);
    },
  );

  testWidgets('cancel confirmation negative keeps the ride active', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();

    await tester.tap(find.text('Keep Ride'));
    await tester.pump();

    expect(find.text('Cancel Ride'), findsOneWidget);
    expect(find.text('Home'), findsNothing);

    await settleAndDispose(tester);
  });

  testWidgets(
    'the overlay back arrow routes through the cancel path without popping',
    (WidgetTester tester) async {
      fixture();
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.reply(200, {
          'ride': {'id': 'ride-1', 'status': 'cancelled'},
        }),
      );
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      expect(find.byType(AppBackButton), findsOneWidget);
      expect(find.byIcon(Icons.arrow_back), findsOneWidget);

      await tester.tap(find.byType(AppBackButton));
      await tester.pump();

      // A live trip reuses the same confirmation the `Cancel Ride` button shows.
      expect(find.text('Cancel this ride?'), findsOneWidget);

      await tester.tap(find.text('Yes, Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(find.text('Home'), findsOneWidget);
      expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

      await settleAndDispose(tester);
    },
  );

  testWidgets('WS cancelled event routes home', (WidgetTester tester) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'cancelled',
        'cancelled_by': 'driver',
      },
    }, settle: true);

    expect(find.text('Home'), findsOneWidget);
    // A driver-side cancel is a cancel: keep the pickup for a retry.
    expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

    await settleAndDispose(tester);
  });

  testWidgets('a second cancel tap while the POST is in flight posts exactly once',
      (WidgetTester tester) async {
    fixture();
    final gate = Completer<void>();
    var cancelPosts = 0;
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.replyCallbackAsync(200, (_) async {
        cancelPosts++;
        await gate.future;
        return {'ride': {'id': 'ride-1', 'status': 'cancelled'}};
      }),
    );
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    // Two taps in the same frame: the first installs the guard synchronously
    // before the `showDialog` await, so the second cannot stack a dialog.
    await tester.tap(find.text('Cancel Ride'));
    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();

    expect(
      find.text('Cancel this ride?'),
      findsOneWidget,
      reason: 'only one confirmation dialog may ever appear',
    );

    await tester.tap(find.text('Yes, Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(cancelPosts, 1);

    // The POST is parked. Both entry points share the guard: the button is
    // disabled, and the back arrow's `_cancelRide` early-returns.
    await tester.tap(find.byType(AppBackButton));
    await tester.pump();
    expect(find.text('Cancel this ride?'), findsNothing);
    expect(cancelPosts, 1);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(cancelPosts, 1, reason: 'one confirmed cancel, one POST');
    expect(find.text('Ride cancelled successfully'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets(
    'the Cancel Ride button is disabled while the cancel POST is in flight',
    (WidgetTester tester) async {
      fixture();
      final gate = Completer<void>();
      var cancelPosts = 0;
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.replyCallbackAsync(200, (_) async {
          cancelPosts++;
          await gate.future;
          return {'ride': {'id': 'ride-1', 'status': 'cancelled'}};
        }),
      );
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      AppButton cancelButton() => tester.widget<AppButton>(
            find.widgetWithText(AppButton, 'Cancel Ride'),
          );
      expect(cancelButton().onPressed, isNotNull);

      await tester.tap(find.text('Cancel Ride'));
      await tester.pump();
      // The busy flag is set before the dialog opens.
      expect(cancelButton().onPressed, isNull);

      await tester.tap(find.text('Yes, Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(cancelPosts, 1);
      expect(cancelButton().onPressed, isNull);

      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      // After completion the screen leaves home rather than re-enabling on a
      // dead trip.
      expect(find.text('Home'), findsOneWidget);

      await settleAndDispose(tester);
    },
  );

  testWidgets(
    'a 200 cancel and the WS cancelled echo show one success SnackBar',
    (WidgetTester tester) async {
      fixture();
      final gate = Completer<void>();
      var cancelPosts = 0;
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.replyCallbackAsync(200, (_) async {
          cancelPosts++;
          await gate.future;
          return {'ride': {'id': 'ride-1', 'status': 'cancelled'}};
        }),
      );
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      await tester.tap(find.text('Cancel Ride'));
      await tester.pump();
      await tester.tap(find.text('Yes, Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(cancelPosts, 1);

      // The server's own `ride.updated cancelled` echo wins the race while the
      // POST is still parked. It must acknowledge and leave once; the POST's
      // later 200 must not add a second SnackBar or navigation.
      await emitAndSettle(tester, {
        'type': 'ride.updated',
        'data': {
          'ride_id': 'ride-1',
          'status': 'cancelled',
          'cancelled_by': 'rider',
        },
      });

      expect(find.text('Home'), findsOneWidget);
      expect(
        find.text('Ride cancelled successfully'),
        findsOneWidget,
        reason: 'one cancellation must be acknowledged once',
      );

      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(cancelPosts, 1);
      expect(find.text('Ride cancelled successfully'), findsOneWidget);

      await settleAndDispose(tester);
    },
  );

  testWidgets('a 404 cancel goes home without a generic error',
      (WidgetTester tester) async {
    fixture();
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.reply(404, {
        'error': {'code': 'NOT_FOUND', 'message': 'ride not found'},
      }),
    );
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();
    await tester.tap(find.text('Yes, Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('ride not found'), findsNothing);
    expect(find.text('Ride not found'), findsNothing);
    expect(find.text('Ride cancelled successfully'), findsNothing);
    // A dead trip view is still a cancel exit: keep the pickup for a retry.
    expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

    await settleAndDispose(tester);
  });

  testWidgets(
    'a 409 cancel shows the API message and does not navigate or retry',
    (WidgetTester tester) async {
      fixture();
      var cancelPosts = 0;
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.replyCallback(409, (_) {
          cancelPosts++;
          return {
            'error': {
              'code': 'CONFLICT',
              'message': 'ride can no longer be cancelled',
            },
          };
        }),
      );
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      await tester.tap(find.text('Cancel Ride'));
      await tester.pump();
      await tester.tap(find.text('Yes, Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(cancelPosts, 1);
      expect(find.text('ride can no longer be cancelled'), findsOneWidget);
      expect(find.text('Home'), findsNothing);

      // A 409 is terminal for this action: no automatic re-POST.
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(cancelPosts, 1);
      expect(find.text('Home'), findsNothing);

      await settleAndDispose(tester);
    },
  );

  testWidgets('a 500 cancel shows a retryable error and does not navigate',
      (WidgetTester tester) async {
    fixture();
    var cancelPosts = 0;
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.replyCallback(500, (_) {
        cancelPosts++;
        return {
          'error': {'code': 'INTERNAL', 'message': 'failed to cancel ride'},
        };
      }),
    );
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();
    await tester.tap(find.text('Yes, Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(cancelPosts, 1);
    expect(find.text('failed to cancel ride'), findsOneWidget);
    expect(find.text('Home'), findsNothing);

    // Drop the error SnackBar (it floats over the sheet's Cancel button), then
    // a fresh tap must find the guard reset: one new dialog and exactly one
    // more POST.
    ScaffoldMessenger.of(tester.element(find.byType(ActiveRideScreen)))
        .removeCurrentSnackBar();
    await tester.pump();

    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();
    expect(find.text('Cancel this ride?'), findsOneWidget);

    await tester.tap(find.text('Yes, Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(cancelPosts, 2);
    expect(find.text('Home'), findsNothing);

    await settleAndDispose(tester);
  });

  testWidgets(
    'holds the rider location ping lease while the trip is on screen',
    (WidgetTester tester) async {
      fixture();
      final ping = FakeLocationPingService(apiClient);
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter(ping: ping));
      await tester.pump();

      expect(ping.startCount, 1);
      expect(ping.isActive, isTrue);

      await settleAndDispose(tester);
    },
  );

  testWidgets(
    'releases the location ping lease when the trip screen is disposed',
    (WidgetTester tester) async {
      fixture();
      final ping = FakeLocationPingService(apiClient);
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter(ping: ping));
      await tester.pump();
      // Let the two entry-path requests finish before the tree is torn down:
      // Dio arms a per-request timer that only clears once the response has been
      // processed, and a swap mid-flight leaves it pending.
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();
      expect(ping.isActive, isTrue);

      // Leaving the flow route (completion, cancel, or `context.go('/home')`)
      // disposes the screen; the service must not keep a lease behind.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(ping.stopCount, 1);
      expect(ping.isActive, isFalse);
    },
  );

  testWidgets('the driver marker moves when a driver.location event lands', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    expect(driverMarkerPoint(tester), const LatLng(9.93, -84.09));

    await emitAndSettle(tester, driverLocationEvent(9.9456, -84.1234));

    expect(driverMarkerPoint(tester), const LatLng(9.9456, -84.1234));
    // The WS fix also restarted the silence window, so nothing polls yet.
    expect(tracker.state.httpPolls, 0);

    await settleAndDispose(tester);
  });

  testWidgets('10 s of WS silence triggers GET /drivers/{id}/location', (
    WidgetTester tester,
  ) async {
    fixture();
    var locationCalls = 0;
    dioAdapter.onGet('/api/v1/drivers/driver-1/location', (server) {
      return server.replyCallback(200, (_) {
        locationCalls++;
        return {
          'driver_id': 'driver-1',
          'lat': 9.95,
          'lng': -84.12,
          'heading': 10.0,
          'speed': 8.0,
          'status': 'en_route',
          'updated_at': '2026-03-01T10:10:00Z',
        };
      });
    });
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    expect(tracker.isPolling, isTrue);

    // One 5 s tick is not enough — the window is 10 s.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(locationCalls, 0);
    expect(tracker.silentTicks, 1);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(locationCalls, 1);
    expect(tracker.state.httpPolls, 1);
    expect(tracker.state.error, isNull);
    // The polled fix is folded into the same marker, not a parallel store.
    expect(driverMarkerPoint(tester), const LatLng(9.95, -84.12));

    await settleAndDispose(tester);
  });

  testWidgets('the tracking tick stops on completed and on dispose', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();
    expect(tracker.isPolling, isTrue);

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'completed',
        'fare': {
          'base_fare': 1200.0,
          'distance_fare': 900.0,
          'time_fare': 700.0,
          'surge_multiplier': 1.25,
          'total': 2800.0,
        },
      },
    }, settle: true);

    expect(
      tracker.isPolling,
      isFalse,
      reason: 'nothing left to track once the ride is over',
    );
    expect(
      find.byKey(const ValueKey<String>('ride-receipt-dialog')),
      findsOneWidget,
    );

    await settleAndDispose(tester);
  });

  testWidgets('completed shows the real receipt then a rating prompt', (
    WidgetTester tester,
  ) async {
    fixture();
    var receiptCalls = 0;
    dioAdapter.onGet('/api/v1/rides/ride-1/receipt', (server) {
      return server.replyCallback(200, (_) {
        receiptCalls++;
        return receiptJson();
      });
    });
    final List<Map<String, dynamic>> ratedBodies = [];
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/rate',
      (server) => server.replyCallback(200, (options) {
        ratedBodies.add(options.data as Map<String, dynamic>);
        return {'message': 'rating submitted'};
      }),
      // A body-carrying POST never matches a route registered without a body
      // expectation under `FullHttpRequestMatcher`; the real body is asserted
      // from the captured `RequestOptions` instead.
      data: Matchers.any,
    );
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    // No `fare` on the event, so the breakdown has to come from the endpoint.
    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'completed'},
    }, settle: true);

    expect(receiptCalls, 1);
    expect(find.text('Ride receipt'), findsOneWidget);
    expect(find.text('Base fare'), findsOneWidget);
    expect(find.text('\$1200.00'), findsOneWidget);
    expect(find.text('Distance fare'), findsOneWidget);
    expect(find.text('\$900.00'), findsOneWidget);
    expect(find.text('Time fare'), findsOneWidget);
    expect(find.text('\$700.00'), findsOneWidget);
    expect(find.text('×1.25'), findsOneWidget);
    expect(find.text('\$2800.00'), findsOneWidget);
    expect(find.text('Fare from the ride receipt.'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Rate your ride'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('rating-star-5')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('rating-star-5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pumpAndSettle();

    expect(ratedBodies, hasLength(1));
    expect(ratedBodies.single['score'], 5);
    expect(ratedBodies.single['comment'], '');
    expect(find.text('Home'), findsOneWidget);
    // A completed trip starts a fresh booking, not the old pickup.
    expect(container.read(pickupMemoryProvider).restoreOnHome, isFalse);

    await settleAndDispose(tester);
  });

  testWidgets('rating one ride does not suppress the next ride prompt [FIX-C]', (
    WidgetTester tester,
  ) async {
    fixture();
    // Ride 1's completion reads.
    dioAdapter.onGet(
      '/api/v1/rides/ride-1/receipt',
      (server) => server.reply(200, receiptJson()),
    );
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/rate',
      (server) => server.reply(200, {'message': 'rating submitted'}),
      data: Matchers.any,
    );
    // Ride 2 is a different trip on the SAME session-scoped providers.
    dioAdapter.onGet(
      '/api/v1/rides/ride-2',
      (server) =>
          server.replyCallback(200, (_) => {'ride': rideJson(id: 'ride-2')}),
    );
    dioAdapter.onGet(
      '/api/v1/rides/ride-2/receipt',
      (server) => server.reply(200, receiptJson(total: 1500.0)),
    );
    final List<Map<String, dynamic>> ratedBodies = [];
    dioAdapter.onPost(
      '/api/v1/rides/ride-2/rate',
      (server) => server.replyCallback(200, (options) {
        ratedBodies.add(options.data as Map<String, dynamic>);
        return {'message': 'rating submitted'};
      }),
      data: Matchers.any,
    );

    // --- Ride 1: complete it and rate it 5★.
    emit(acceptedEvent());
    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'completed'},
    }, settle: true);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Rate your ride'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('rating-star-5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);

    // --- Ride 2 on the same session. Before FIX-C the global
    // `rating == submitted` from ride 1 made `canRate('ride-2')` false, so the
    // receipt still showed but the prompt was skipped.
    emit(acceptedEvent(rideId: 'ride-2', driverId: 'driver-2'));
    await tester.pump();
    await tester.tap(find.text('Start next ride'));
    await tester.pumpAndSettle();

    expect(
      find.text('Cancel Ride'),
      findsOneWidget,
      reason: 'ride 2 must mount as a normal active trip',
    );

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-2', 'status': 'completed'},
    }, settle: true);

    expect(find.text('Ride receipt'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(
      find.text('Rate your ride'),
      findsOneWidget,
      reason: 'FIX-C: the earlier rating must not gate this ride',
    );
    await tester.tap(find.byKey(const ValueKey<String>('rating-star-4')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pumpAndSettle();

    expect(ratedBodies, hasLength(1));
    expect(ratedBodies.single['score'], 4);
    expect(find.text('Home'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('the WS fare is shown without reading the receipt endpoint', (
    WidgetTester tester,
  ) async {
    fixture();
    var receiptCalls = 0;
    dioAdapter.onGet('/api/v1/rides/ride-1/receipt', (server) {
      return server.replyCallback(200, (_) {
        receiptCalls++;
        return receiptJson();
      });
    });
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'completed',
        'fare': {
          'base_fare': 1000.0,
          'distance_fare': 500.0,
          'time_fare': 300.0,
          'surge_multiplier': 2.0,
          'total': 1800.0,
        },
      },
    }, settle: true);

    expect(receiptCalls, 0);
    expect(find.text('\$1800.00'), findsOneWidget);
    expect(find.text('Fare from your live trip.'), findsOneWidget);

    // Skip the prompt; the flow still routes home.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('a ride already in the rated history skips the prompt', (
    WidgetTester tester,
  ) async {
    fixture();
    dioAdapter.onGet(
      '/api/v1/rider/ratings',
      (server) => server.reply(200, {
        'ratings': [
          {
            'id': 'r1',
            'ride_id': 'ride-1',
            'rater_role': 'rider',
            'score': 5,
            'comment': '',
            'created_at': '2026-03-01T11:00:00Z',
          },
        ],
        'total': 1,
        'page': 1,
        'per_page': 50,
        'total_pages': 1,
      }),
    );
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'completed'},
    }, settle: true);

    expect(find.text('Ride receipt'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Rate your ride'), findsNothing);
    expect(find.text('Home'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('View receipt opens the same breakdown mid-trip', (
    WidgetTester tester,
  ) async {
    fixture();
    dioAdapter.onGet(
      '/api/v1/rides/ride-1/receipt',
      (server) => server.reply(200, receiptJson()),
    );
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    // The button only exists once there is a driver position to report on.
    expect(find.text('View receipt'), findsOneWidget);
    await tester.tap(find.text('View receipt'));
    await tester.pumpAndSettle();

    expect(find.text('Ride receipt'), findsOneWidget);
    expect(find.text('\$2800.00'), findsOneWidget);

    await tester.pumpAndSettle();

    // Still on the trip, not routed home.
    expect(find.text('Cancel Ride'), findsOneWidget);

    await settleAndDispose(tester);
  });

  // ---------------------------------------------------------------------------
  // [ontrip] — live road route + ETA
  // ---------------------------------------------------------------------------

  testWidgets('renders the API road route as the trip polyline', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final line = tripPolyline(tester);
    expect(line, isNotNull, reason: 'a ready road route must be drawn');
    // Three points from the mock API (from,road mid,to) — not a synthesized
    // two-point rider→driver straight line.
    expect(line!.points, hasLength(3));
    expect(line.points[1], LatLng((9.9281 + 9.94) / 2, (-84.0907 - 84.10) / 2));
    expect(line.pattern, const StrokePattern.solid());
    expect(line.color, Colors.blue);
    // No honest-fallback banner when the route is a real road route.
    expect(
      find.byKey(const ValueKey<String>('trip-route-estimate')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('trip-route-error')),
      findsNothing,
    );

    await settleAndDispose(tester);
  });

  testWidgets(
    'an is_estimate route is labeled and drawn dashed, not as a road route',
    (WidgetTester tester) async {
      fixture(route: RouteMock.estimate);
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await pumpRoute(tester);

      expect(
        find.byKey(const ValueKey<String>('trip-route-estimate')),
        findsOneWidget,
      );
      expect(find.text('Estimated route'), findsOneWidget);
      final line = tripPolyline(tester);
      expect(line, isNotNull);
      expect(line!.color, Colors.grey);
      expect(line.pattern, isNot(const StrokePattern.solid()));

      await settleAndDispose(tester);
    },
  );

  testWidgets(
    'a 422 route response surfaces an error state, never a confident line',
    (WidgetTester tester) async {
      fixture(route: RouteMock.http422);
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await pumpRoute(tester);

      expect(
        find.byKey(const ValueKey<String>('trip-route-error')),
        findsOneWidget,
      );
      expect(find.text('Route unavailable'), findsOneWidget);
      expect(find.text('invalid coordinates'), findsOneWidget);
      expect(
        find.byType(PolylineLayer),
        findsNothing,
        reason: 'a failed route must not draw any geometry at all',
      );

      await settleAndDispose(tester);
    },
  );

  testWidgets(
    'a 500 route response surfaces an error state, never a confident line',
    (WidgetTester tester) async {
      fixture(route: RouteMock.http500);
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await pumpRoute(tester);

      expect(
        find.byKey(const ValueKey<String>('trip-route-error')),
        findsOneWidget,
      );
      expect(find.text('failed to calculate route'), findsOneWidget);
      expect(find.byType(PolylineLayer), findsNothing);

      await settleAndDispose(tester);
    },
  );

  testWidgets('the 300 s ETA placeholder renders as unknown, not "5 min"', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent(etaSeconds: 300));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final eta = tester.widget<Text>(
      find.byKey(const ValueKey<String>('trip-eta')),
    );
    expect(eta.data, 'ETA unavailable');
    expect(find.text('ETA 5 min'), findsNothing);

    await settleAndDispose(tester);
  });

  testWidgets('a real ETA is shown on the active trip', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent(etaSeconds: 240));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final eta = tester.widget<Text>(
      find.byKey(const ValueKey<String>('trip-eta')),
    );
    expect(eta.data, 'ETA 4 min');

    await settleAndDispose(tester);
  });

  testWidgets('a destination change re-requests the route for the new leg', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    expect(routeRequests, hasLength(1));
    expect(routeRequests.single['to_lat'], 9.94);

    // The server now reports the changed destination; the client re-reads the
    // itinerary and re-routes rather than waiting for a server-side re-route.
    rideResponse = {
      'ride': rideJson(
        status: 'in_progress',
        dropoffLat: 9.96,
        dropoffLng: -84.13,
      ),
      'stops': <dynamic>[],
    };
    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'in_progress',
        'dropoff': {'lat': 9.96, 'lng': -84.13},
      },
    });
    await pumpRoute(tester);

    expect(routeRequests.length, greaterThanOrEqualTo(2));
    expect(routeRequests.last['to_lat'], 9.96);
    expect(routeRequests.last['to_lng'], -84.13);

    await settleAndDispose(tester);
  });

  testWidgets('changing destination searches then PUTs the picked place', (
    WidgetTester tester,
  ) async {
    fixture();
    const newDestination = Place(
      id: 'new-dest',
      name: 'New Destination',
      address: 'New Rd',
      lat: 9.97,
      lng: -84.14,
    );
    final putBodies = <Map<String, dynamic>>[];
    dioAdapter.onPut(
      '/api/v1/rides/ride-1/destination',
      (server) => server.replyCallback(200, (options) {
        putBodies.add(Map<String, dynamic>.from(options.data as Map));
        return {'ride': rideJson(status: 'in_progress')};
      }),
      // A body-carrying PUT never matches a route registered without a body
      // expectation under the default matcher; the real body is asserted from
      // the captured `RequestOptions` instead.
      data: Matchers.any,
    );
    emit(acceptedEvent());

    await tester.pumpWidget(
      buildRouter(changeDestinationResult: newDestination),
    );
    await tester.pump();

    final button = find.byKey(
      const ValueKey<String>('change-destination-button'),
    );
    expect(button, findsOneWidget, reason: 'accepted rides are changeable');
    await tester.tap(button);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    // The confirmation shows the fresh estimate before any mutation; only
    // Confirm fires the PUT.
    expect(
      find.byKey(const ValueKey<String>('change-destination-dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('change-destination-estimate')),
      findsOneWidget,
    );
    expect(
      putBodies,
      isEmpty,
      reason: 'the ride must be untouched until Confirm',
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('change-destination-confirm')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(putBodies, hasLength(1));
    expect(putBodies.single, {'lat': 9.97, 'lng': -84.14, 'address': 'New Rd'});
    expect(find.text('Destination updated'), findsOneWidget);

    await settleAndDispose(tester);
  });

  // ---------------------------------------------------------------------------
  // Bug #21 — change-destination search with no origin. The `_searchBias()`
  // center biases the request only; it is never written into the booking or the
  // destination, so the search opens with a non-null center. That the real
  // screen's blocking branch requires a null center is covered by the
  // negative-control pair in `location_search_screen_test.dart`.
  // ---------------------------------------------------------------------------

  testWidgets(
    'no pickup: change-destination search opens with a bias and routes the picked place',
    (WidgetTester tester) async {
      fixture();
      const newDestination = Place(
        id: 'new-dest',
        name: 'New Destination',
        address: 'New Rd',
        lat: 9.97,
        lng: -84.14,
      );
      final searchExtras = <Map<String, dynamic>>[];
      final putBodies = <Map<String, dynamic>>[];
      dioAdapter.onPut(
        '/api/v1/rides/ride-1/destination',
        (server) => server.replyCallback(200, (options) {
          putBodies.add(Map<String, dynamic>.from(options.data as Map));
          return {'ride': rideJson(status: 'in_progress')};
        }),
        data: Matchers.any,
      );
      // No pickup on the accept payload and no device fix on the active trip.
      emit(acceptedEvent(includePickup: false));

      await tester.pumpWidget(
        buildRouter(
          changeDestinationResult: newDestination,
          searchExtras: searchExtras,
        ),
      );
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey<String>('change-destination-button')),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      // The search opened with a non-null bias (the fallback center); with no
      // routeable pickup the confirmation is honest about the missing estimate
      // and still offers Confirm.
      expect(searchExtras, hasLength(1));
      expect(searchExtras.single['hint'], 'Where to?');
      expect(searchExtras.single['lat'], isNotNull);
      expect(searchExtras.single['lng'], isNotNull);
      expect(
        find.byKey(const ValueKey<String>('change-destination-no-estimate')),
        findsOneWidget,
      );
      expect(putBodies, isEmpty);

      await tester.tap(
        find.byKey(const ValueKey<String>('change-destination-confirm')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(putBodies, hasLength(1));
      expect(putBodies.single, {
        'lat': 9.97,
        'lng': -84.14,
        'address': 'New Rd',
      });

      // The server now reports the picked destination; the screen re-reads the
      // itinerary and re-routes the new leg with the picked coordinates.
      rideResponse = {
        'ride': rideJson(
          status: 'in_progress',
          dropoffLat: 9.97,
          dropoffLng: -84.14,
        ),
        'stops': <dynamic>[],
      };
      await emitAndSettle(tester, {
        'type': 'ride.updated',
        'data': {
          'ride_id': 'ride-1',
          'status': 'in_progress',
          'dropoff': {'lat': 9.97, 'lng': -84.14},
        },
      });
      await pumpRoute(tester);

      expect(routeRequests, isNotEmpty);
      expect(routeRequests.last['to_lat'], 9.97);
      expect(routeRequests.last['to_lng'], -84.14);

      await settleAndDispose(tester);
    },
  );

  testWidgets(
    'the change-destination entry is absent outside changeable statuses',
    (WidgetTester tester) async {
      fixture();

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      // `idle` is not in the API's changeable set, so no entry is offered.
      expect(
        find.byKey(const ValueKey<String>('change-destination-button')),
        findsNothing,
      );

      await settleAndDispose(tester);
    },
  );

  testWidgets('the refresh tick re-reads the route on its injected schedule', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(
      buildRouter(routeRefreshInterval: const Duration(milliseconds: 100)),
    );
    await pumpRoute(tester); // 80 ms of fake time — below the 100 ms tick.
    expect(routeRequests, hasLength(1));

    await tester.pump(const Duration(milliseconds: 30)); // crosses the tick
    await pumpRoute(tester);
    expect(routeRequests.length, greaterThanOrEqualTo(2));

    await settleAndDispose(tester);
  });

  testWidgets('the trip-route refresh tick stops on completed', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    expect(tripRoute.isPolling, isTrue);

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'completed',
        // A WS fare keeps `resolveFare` off the receipt endpoint.
        'fare': {
          'base_fare': 1000.0,
          'distance_fare': 500.0,
          'time_fare': 300.0,
          'surge_multiplier': 1.0,
          'total': 1800.0,
        },
      },
    }, settle: true);

    expect(
      tripRoute.isPolling,
      isFalse,
      reason: 'nothing left to route once the ride is over',
    );

    await settleAndDispose(tester);
  });

  testWidgets('the trip-route refresh tick stops on cancelled', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    expect(tripRoute.isPolling, isTrue);

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'cancelled',
        'cancelled_by': 'rider',
      },
    }, settle: true);

    expect(tripRoute.isPolling, isFalse);

    await settleAndDispose(tester);
  });

  testWidgets('the trip-route refresh tick stops when the screen is disposed', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    expect(tripRoute.isPolling, isTrue);

    await tester.pumpWidget(const SizedBox());
    // Dio leaves a zero-duration timer per in-flight request; let it drain so
    // the framework's pending-timer check is about the route tick, not HTTP.
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(tripRoute.isPolling, isFalse);
  });

  // ---------------------------------------------------------------------------
  // [ontrip] status labels (Known bug #29) — the chip must be truthful per
  // status, never the generic `Matching`.
  // ---------------------------------------------------------------------------

  testWidgets('driver_arrived renders "Driver arrived", not "Matching"', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'driver_arrived'},
    });

    expect(find.text('Driver arrived'), findsOneWidget);
    expect(find.text('Matching'), findsNothing);
    // No countdown to an event that already happened; the arrived row instead.
    expect(find.byKey(const ValueKey<String>('trip-eta')), findsNothing);
    expect(find.byKey(const ValueKey<String>('trip-arrived')), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('matching renders "Finding your driver", not "Matching"', (
    WidgetTester tester,
  ) async {
    fixture();
    emit({
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'pending'},
    });

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    expect(find.text('Finding your driver'), findsOneWidget);
    expect(find.text('Matching'), findsNothing);

    await settleAndDispose(tester);
  });

  testWidgets('no_driver_available renders "No drivers found"', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'no_driver_available'},
    });

    expect(find.text('No drivers found'), findsOneWidget);
    expect(find.text('Matching'), findsNothing);

    await settleAndDispose(tester);
  });

  testWidgets('onTrip renders the status with no arrival countdown', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'in_progress'},
    });

    expect(find.text('On Trip'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('trip-eta')), findsNothing);
    expect(find.byKey(const ValueKey<String>('trip-arrived')), findsNothing);

    await settleAndDispose(tester);
  });

  // ---------------------------------------------------------------------------
  // [ontrip] R-3 — ordered stop + destination markers on the active map.
  // ---------------------------------------------------------------------------

  testWidgets('the active map marks intermediate stops and the destination', (
    WidgetTester tester,
  ) async {
    fixture(stops: [
      {
        'id': 'stop-1',
        'ride_id': 'ride-1',
        'sequence': 1,
        'kind': 'stop',
        'lat': 9.93,
        'lng': -84.095,
        'address': 'Stop 1',
      },
      {
        'id': 'stop-2',
        'ride_id': 'ride-1',
        'sequence': 2,
        'kind': 'destination',
        'lat': 9.94,
        'lng': -84.10,
        'address': 'Airport Rd',
      },
    ]);
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    final stops = layer.markers
        .where((m) =>
            m.child is Icon &&
            (m.child as Icon).icon == Icons.trip_origin)
        .toList();
    final destinations = layer.markers
        .where((m) =>
            m.child is Icon && (m.child as Icon).icon == Icons.location_on)
        .toList();

    expect(stops, hasLength(1));
    expect(stops.single.point, const LatLng(9.93, -84.095));
    expect(destinations, hasLength(1));
    expect(destinations.single.point, const LatLng(9.94, -84.10));
    // The rider/driver markers are untouched.
    expect(driverMarkerPoint(tester), const LatLng(9.93, -84.09));

    await settleAndDispose(tester);
  });

  testWidgets('without stops the active map draws no itinerary markers', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    expect(
      layer.markers.where(
        (m) => m.child is Icon && (m.child as Icon).icon == Icons.trip_origin,
      ),
      isEmpty,
    );

    await settleAndDispose(tester);
  });

  // ---------------------------------------------------------------------------
  // [ontrip] R-1 — change-destination confirmation only mutates on Confirm.
  // ---------------------------------------------------------------------------

  testWidgets('cancelling the change-destination confirmation leaves the ride', (
    WidgetTester tester,
  ) async {
    fixture();
    const newDestination = Place(
      id: 'new-dest',
      name: 'New Destination',
      address: 'New Rd',
      lat: 9.97,
      lng: -84.14,
    );
    final putBodies = <Map<String, dynamic>>[];
    dioAdapter.onPut(
      '/api/v1/rides/ride-1/destination',
      (server) => server.replyCallback(200, (options) {
        putBodies.add(Map<String, dynamic>.from(options.data as Map));
        return {'ride': rideJson(status: 'in_progress')};
      }),
      data: Matchers.any,
    );
    emit(acceptedEvent());

    await tester.pumpWidget(
      buildRouter(changeDestinationResult: newDestination),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('change-destination-button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('change-destination-dialog')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('change-destination-cancel')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(putBodies, isEmpty, reason: 'Cancel must not mutate the ride');
    expect(
      find.byKey(const ValueKey<String>('change-destination-dialog')),
      findsNothing,
    );
    // Still on the trip.
    expect(find.text('Cancel Ride'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('an estimate outage still offers Confirm and then PUTs', (
    WidgetTester tester,
  ) async {
    fixture(estimateStatus: 500);
    const newDestination = Place(
      id: 'new-dest',
      name: 'New Destination',
      address: 'New Rd',
      lat: 9.97,
      lng: -84.14,
    );
    final putBodies = <Map<String, dynamic>>[];
    dioAdapter.onPut(
      '/api/v1/rides/ride-1/destination',
      (server) => server.replyCallback(200, (options) {
        putBodies.add(Map<String, dynamic>.from(options.data as Map));
        return {'ride': rideJson(status: 'in_progress')};
      }),
      data: Matchers.any,
    );
    emit(acceptedEvent());

    await tester.pumpWidget(
      buildRouter(changeDestinationResult: newDestination),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('change-destination-button')),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    // No advisory number must veto the rider's legitimate action.
    expect(
      find.byKey(const ValueKey<String>('change-destination-no-estimate')),
      findsOneWidget,
    );
    expect(putBodies, isEmpty);

    await tester.tap(
      find.byKey(const ValueKey<String>('change-destination-confirm')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(putBodies, hasLength(1));

    await settleAndDispose(tester);
  });

  // ---------------------------------------------------------------------------
  // [ontrip] R1 — client-computed live arrival ETA.
  // ---------------------------------------------------------------------------

  testWidgets('a live /geo/eta result updates the ETA row with distance', (
    WidgetTester tester,
  ) async {
    fixture(
      etaReply: {
        'eta_seconds': 240,
        'distance_meters': 2300,
        'is_estimate': false,
      },
    );
    // The accept payload carries the unknown placeholder; the client compute
    // must replace it with the real live number.
    emit(acceptedEvent(etaSeconds: 300));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final eta = tester.widget<Text>(
      find.byKey(const ValueKey<String>('trip-eta')),
    );
    expect(eta.data, '2.3 km · ETA 4 min');

    await settleAndDispose(tester);
  });

  // ---------------------------------------------------------------------------
  // [arrival] — the "driver is nearby" notice consumes the server flag only.
  // ---------------------------------------------------------------------------

  testWidgets('near_pickup shows the nearby notice with the distance', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    // Before any near fix, no notice is invented.
    expect(
      find.byKey(const ValueKey<String>('driver-nearby-notice')),
      findsNothing,
    );

    await emitAndSettle(tester, {
      'type': 'driver.location',
      'data': {
        'ride_id': 'ride-1',
        'driver_id': 'driver-1',
        'lat': 9.9285,
        'lng': -84.091,
        'heading': 0,
        'speed': 0,
        'near_pickup': true,
        'distance_to_pickup_m': 120.0,
      },
    });

    expect(
      find.byKey(const ValueKey<String>('driver-nearby-notice')),
      findsOneWidget,
    );
    expect(find.textContaining('120 m away'), findsOneWidget);

    await settleAndDispose(tester);
  });

  testWidgets('arrival clears the nearby notice and shows the arrived row', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await emitAndSettle(tester, {
      'type': 'driver.location',
      'data': {
        'ride_id': 'ride-1',
        'driver_id': 'driver-1',
        'lat': 9.9285,
        'lng': -84.091,
        'heading': 0,
        'speed': 0,
        'near_pickup': true,
        'distance_to_pickup_m': 120.0,
      },
    });
    expect(
      find.byKey(const ValueKey<String>('driver-nearby-notice')),
      findsOneWidget,
    );

    await emitAndSettle(tester, {
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'driver_arrived'},
    });

    expect(
      find.byKey(const ValueKey<String>('driver-nearby-notice')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey<String>('trip-arrived')), findsOneWidget);

    await settleAndDispose(tester);
  });

  // [map] shared locate/fit button.
  // ---------------------------------------------------------------------------

  testWidgets('the locate button sits above the driver sheet, right-aligned', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);

    final button = tester.getRect(locateButton());
    final sheet = tester.getRect(find.byType(AppBottomSheet));
    expect(button.right, closeTo(800 - 16, 0.1));
    expect(button.bottom, lessThanOrEqualTo(sheet.top));

    await settleAndDispose(tester);
  });

  testWidgets('route load auto-fits and the first tap locates the driver', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    await tester.pump();

    expect(find.byTooltip('Current location'), findsOneWidget);
    final fitted = mapCamera(tester).visibleBounds;
    expect(fitted.contains(const LatLng(9.9281, -84.0907)), isTrue);
    expect(fitted.contains(const LatLng(9.94, -84.10)), isTrue);

    await tester.tap(locateButton());
    await tester.pump();
    await tester.pump();

    final camera = mapCamera(tester);
    expect(camera.center.latitude, closeTo(9.93, 0.0001));
    expect(camera.center.longitude, closeTo(-84.09, 0.0001));
    expect(camera.zoom, 16);
    expect(find.byTooltip('Fit route'), findsOneWidget);

    await settleAndDispose(tester);
  });

  for (final status in const [
    'matching',
    'driverApproaching',
    'driverArrived',
    'onTrip',
  ]) {
    testWidgets('$status locates the driver fix', (WidgetTester tester) async {
      fixture();
      final backendStatus = switch (status) {
        'matching' => 'pending',
        'driverArrived' => 'driver_arrived',
        'onTrip' => 'in_progress',
        _ => 'accepted',
      };
      rideResponse = {
        'ride': rideJson(status: backendStatus),
        'stops': <dynamic>[],
      };
      emit(acceptedEvent());
      // `pending` resets the whole state, so the fix must land after it.
      if (status == 'matching') emit(statusEvent('pending'));
      emit(driverLocationEvent(9.93, -84.09));
      if (status == 'driverArrived' || status == 'onTrip') {
        emit(statusEvent(backendStatus));
      }

      await tester.pumpWidget(buildRouter());
      await pumpRoute(tester);
      await tester.pump();

      expect(find.byTooltip('Current location'), findsOneWidget);
      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();

      final camera = mapCamera(tester);
      expect(camera.center.latitude, closeTo(9.93, 0.0001));
      expect(camera.center.longitude, closeTo(-84.09, 0.0001));
      expect(camera.zoom, 16);

      await settleAndDispose(tester);
    });
  }

  for (final backendStatus in const [
    'completed',
    'cancelled',
    'no_driver_available',
  ]) {
    testWidgets(
      '$backendStatus locates the rider fix, not the retained driver fix',
      (WidgetTester tester) async {
        fixture();
        // Seed the terminal state directly, before mount: the WS listener and
        // the completion/cancel exits must not run for this camera assertion.
        // The retained driver fix proves the terminal branch ignores it.
        rideNotifier.updateFromCurrentRide({
          'id': null,
          'status': backendStatus,
        });
        rideNotifier.applyDriverLocation(
          const DriverLocation(driverId: 'driver-1', lat: 9.93, lng: -84.09),
        );

        await tester.pumpWidget(
          buildRouter(riderFix: () async => const LatLng(9.91, -84.07)),
        );
        await pumpRoute(tester);
        await tester.pump();

        await tester.tap(locateButton());
        await tester.pump();
        await tester.pump();

        final camera = mapCamera(tester);
        expect(camera.center.latitude, closeTo(9.91, 0.0001));
        expect(camera.center.longitude, closeTo(-84.07, 0.0001));
        expect(camera.zoom, 16);

        await settleAndDispose(tester);
      },
    );
  }

  testWidgets('idle locates the rider fix', (WidgetTester tester) async {
    fixture();

    await tester.pumpWidget(
      buildRouter(riderFix: () async => const LatLng(9.91, -84.07)),
    );
    await tester.pump();

    expect(find.byTooltip('Current location'), findsOneWidget);
    await tester.tap(locateButton());
    await tester.pump();
    await tester.pump();

    final camera = mapCamera(tester);
    expect(camera.center.latitude, closeTo(9.91, 0.0001));
    expect(camera.center.longitude, closeTo(-84.07, 0.0001));
    expect(camera.zoom, 16);

    await settleAndDispose(tester);
  });

  testWidgets('the button cycles locate → fit route → locate', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    await tester.pump();

    // Auto-fit is the fit half; tap 1 locates the driver.
    await tester.tap(locateButton());
    await tester.pump();
    await tester.pump();
    var camera = mapCamera(tester);
    expect(camera.center.latitude, closeTo(9.93, 0.0001));
    expect(find.byTooltip('Fit route'), findsOneWidget);

    // Tap 2 fits the trip route.
    await tester.tap(locateButton());
    await tester.pump();
    camera = mapCamera(tester);
    expect(
      camera.visibleBounds.contains(const LatLng(9.9281, -84.0907)),
      isTrue,
    );
    expect(camera.visibleBounds.contains(const LatLng(9.94, -84.10)), isTrue);
    expect(find.byTooltip('Current location'), findsOneWidget);

    // Tap 3 locates the driver again.
    await tester.tap(locateButton());
    await tester.pump();
    await tester.pump();
    camera = mapCamera(tester);
    expect(camera.center.latitude, closeTo(9.93, 0.0001));
    expect(camera.center.longitude, closeTo(-84.09, 0.0001));

    await settleAndDispose(tester);
  });

  testWidgets(
    'a driving status with no driver fix says so and does not move the camera',
    (WidgetTester tester) async {
      fixture();
      emit(acceptedEvent());

      await tester.pumpWidget(buildRouter());
      await pumpRoute(tester);
      await tester.pump();

      expect(rideNotifier.state.driverLocation, isNull);
      final before = mapCamera(tester).center;

      await tester.tap(locateButton());
      await tester.pump();
      await tester.pump();

      expect(find.text('Waiting for driver location…'), findsOneWidget);
      expect(find.byTooltip('Current location'), findsOneWidget);
      expect(mapCamera(tester).center.latitude, closeTo(before.latitude, 1e-9));
      expect(
        mapCamera(tester).center.longitude,
        closeTo(before.longitude, 1e-9),
      );

      await settleAndDispose(tester);
    },
  );

  testWidgets('driver follow still re-centers after a locate press', (
    WidgetTester tester,
  ) async {
    fixture();
    emit(acceptedEvent());
    emit(driverLocationEvent(9.93, -84.09));

    await tester.pumpWidget(buildRouter());
    await pumpRoute(tester);
    await tester.pump();

    await tester.tap(locateButton());
    await tester.pump();
    await tester.pump();
    expect(mapCamera(tester).center.latitude, closeTo(9.93, 0.0001));

    // A newer fix must still re-center (the locate press never pauses follow).
    await emitAndSettle(tester, driverLocationEvent(9.935, -84.095));

    final camera = mapCamera(tester);
    expect(camera.center.latitude, closeTo(9.935, 0.0001));
    expect(camera.center.longitude, closeTo(-84.095, 0.0001));
    expect(camera.zoom, 16);

    await settleAndDispose(tester);
  });
}
