import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:latlong2/latlong.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/features/home/data/trip_eta.dart';
import 'package:rider_app/features/home/data/trip_route_provider.dart';

/// The road route the mock API answers, reflecting the requested leg so a
/// multi-leg trip visibly concatenates instead of collapsing onto one line.
Map<String, dynamic> roadRoute(RequestOptions options) {
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

Map<String, dynamic> rideJson({
  double pickupLat = 9.9281,
  double pickupLng = -84.0907,
  double dropoffLat = 9.94,
  double dropoffLng = -84.10,
}) {
  return {
    'id': 'ride-1',
    'status': 'in_progress',
    'pickup_lat': pickupLat,
    'pickup_lng': pickupLng,
    'dropoff_lat': dropoffLat,
    'dropoff_lng': dropoffLng,
    'pickup_address': 'Main St',
    'dropoff_address': 'Airport Rd',
  };
}

Map<String, dynamic> stopJson(int sequence, String kind, double lat, double lng) => {
      'id': 'stop-$sequence',
      'ride_id': 'ride-1',
      'sequence': sequence,
      'kind': kind,
      'lat': lat,
      'lng': lng,
      'address': '',
    };

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late TripRouteNotifier notifier;
  late List<Map<String, dynamic>> routeRequests;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
    notifier = TripRouteNotifier(apiClient);
    routeRequests = [];
  });

  tearDown(() => notifier.dispose());

  void mockRide(Map<String, dynamic> body) {
    dioAdapter.onGet(
      '/api/v1/rides/ride-1',
      (server) => server.replyCallback(200, (_) => body),
    );
  }

  void mockRoute(int status, Map<String, dynamic> Function(RequestOptions) body) {
    dioAdapter.onGet(
      '/api/v1/navigation/route',
      (server) => server.replyCallback(status, (options) {
        routeRequests.add(Map<String, dynamic>.from(options.queryParameters));
        return body(options);
      }),
    );
  }

  test('a rides without a stops key degrades to one pickup→dropoff leg',
      () async {
    mockRide({'ride': rideJson()});
    mockRoute(200, roadRoute);

    await notifier.load('ride-1');

    expect(notifier.state.status, TripRouteStatus.ready);
    expect(notifier.state.hasRoadRoute, isTrue);
    expect(notifier.state.polyline, hasLength(3));
    expect(routeRequests, hasLength(1));
    expect(routeRequests.single['to_lat'], 9.94);
    expect(notifier.state.totalDistanceM, 1500.0);
  });

  test('intermediate stops become route legs and the destination is not doubled',
      () async {
    mockRide({
      'ride': rideJson(),
      'stops': [
        stopJson(1, 'stop', 9.93, -84.095),
        stopJson(2, 'destination', 9.94, -84.10),
      ],
    });
    mockRoute(200, roadRoute);

    await notifier.load('ride-1');

    expect(notifier.state.status, TripRouteStatus.ready);
    // Leg 1 pickup→stop1 and leg 2 stop1→destination, sharing the stop point.
    expect(routeRequests, hasLength(2));
    expect(routeRequests.first['to_lat'], 9.93);
    expect(routeRequests.last['from_lat'], 9.93);
    expect(notifier.state.polyline, hasLength(5));
    expect(notifier.state.polyline.first, const LatLng(9.9281, -84.0907));
    expect(notifier.state.polyline.last, const LatLng(9.94, -84.10));
  });

  test('an is_estimate response is flagged, not presented as a road route',
      () async {
    mockRide({'ride': rideJson()});
    mockRoute(200, (options) => {
          ...roadRoute(options),
          'is_estimate': true,
        });

    await notifier.load('ride-1');

    expect(notifier.state.status, TripRouteStatus.estimate);
    expect(notifier.state.isEstimate, isTrue);
    expect(notifier.state.hasRoadRoute, isFalse);
    expect(notifier.state.message, isNotNull);
    expect(notifier.state.message, contains('mapped road network'));
  });

  test('a 422 leaves no geometry to draw', () async {
    mockRide({'ride': rideJson()});
    mockRoute(422, (_) => {
          'error': {'code': 'VALIDATION_ERROR', 'message': 'invalid coordinates'},
        });

    await notifier.load('ride-1');

    expect(notifier.state.status, TripRouteStatus.unavailable);
    expect(notifier.state.hasError, isTrue);
    expect(notifier.state.polyline, isEmpty);
    expect(notifier.state.message, 'invalid coordinates');
  });

  test('a 500 leaves no geometry to draw', () async {
    mockRide({'ride': rideJson()});
    mockRoute(500, (_) => {
          'error': {'code': 'INTERNAL', 'message': 'failed to calculate route'},
        });

    await notifier.load('ride-1');

    expect(notifier.state.status, TripRouteStatus.unavailable);
    expect(notifier.state.polyline, isEmpty);
    expect(notifier.state.message, 'failed to calculate route');
  });

  test('a ride with no routeable pickup fails closed', () async {
    mockRide({
      'ride': {
        'id': 'ride-1',
        'status': 'in_progress',
        'dropoff_lat': 9.94,
        'dropoff_lng': -84.10,
      },
    });

    await notifier.load('ride-1');

    expect(notifier.state.status, TripRouteStatus.unavailable);
    expect(notifier.state.polyline, isEmpty);
    expect(routeRequests, isEmpty);
  });

  test('the refresh tick lives only while started', () async {
    expect(notifier.isPolling, isFalse);
    notifier.start();
    expect(notifier.isPolling, isTrue);
    // Idempotent: a second start does not stack a second timer.
    notifier.start();
    notifier.stop();
    expect(notifier.isPolling, isFalse);
  });

  test('the injected clock stamps the fetched route', () async {
    final fixed = DateTime(2026, 3, 1, 10);
    final clocked = TripRouteNotifier(
      apiClient,
      now: () => fixed,
    );
    addTearDown(clocked.dispose);
    mockRide({'ride': rideJson()});
    mockRoute(200, roadRoute);

    await clocked.load('ride-1');

    expect(clocked.state.fetchedAt, fixed);
  });

  group('etaLabel', () {
    test('the 300 s backend placeholder is unknown, never "5 min"', () {
      expect(etaLabel(unknownEtaSeconds), isNull);
      expect(etaLabel(300), isNull);
    });

    test('a missing or non-positive value is unknown', () {
      expect(etaLabel(null), isNull);
      expect(etaLabel(0), isNull);
      expect(etaLabel(-5), isNull);
    });

    test('a real duration rounds up to the next minute', () {
      expect(etaLabel(240), '4 min');
      expect(etaLabel(299), '5 min');
      expect(etaLabel(30), '1 min');
      expect(etaLabel(301), '6 min');
    });
  });
}
