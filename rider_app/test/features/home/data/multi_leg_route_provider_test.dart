import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:latlong2/latlong.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/multi_leg_route_provider.dart';

/// A road-shaped answer that reflects the requested leg, so a concatenated
/// preview is visibly made of its legs instead of one collapsed line.
Map<String, dynamic> roadRoute(RequestOptions options, {bool estimate = false}) {
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

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late ProviderContainer container;
  late List<Map<String, dynamic>> routeRequests;

  const plan = RoutePlan(
    fromLat: 9.9281,
    fromLng: -84.0907,
    toLat: 9.94,
    toLng: -84.10,
    stops: [RouteWaypoint(9.93, -84.095)],
  );

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
    routeRequests = <Map<String, dynamic>>[];
    container = ProviderContainer(
      overrides: [apiClientProvider.overrideWithValue(apiClient)],
    );
    addTearDown(container.dispose);
  });

  void mockRoute(
    int status,
    Map<String, dynamic> Function(RequestOptions) body,
  ) {
    dioAdapter.onGet(
      '/api/v1/navigation/route',
      (server) => server.replyCallback(status, (options) {
        routeRequests.add(Map<String, dynamic>.from(options.queryParameters));
        return body(options);
      }),
    );
  }

  test('routes each consecutive pair and concatenates the legs', () async {
    mockRoute(200, roadRoute);

    final route = await container.read(multiLegRouteProvider(plan).future);

    // pickup → stop 1, then stop 1 → destination.
    expect(routeRequests, hasLength(2));
    expect(routeRequests.first['to_lat'], 9.93);
    expect(routeRequests.last['from_lat'], 9.93);
    // Two 3-point legs sharing the stop point: 3 + 3 − 1 duplicated.
    expect(route.polyline, hasLength(5));
    expect(route.polyline.first, const LatLng(9.9281, -84.0907));
    expect(route.polyline.last, const LatLng(9.94, -84.10));
    // Neither the destination nor the stop is doubled.
    expect(route.polyline.where((p) => p == const LatLng(9.94, -84.10)),
        hasLength(1));
    expect(route.isEstimate, isFalse);
    expect(route.totalDistanceM, 3000.0);
    expect(route.totalDurationS, 360.0);
  });

  test('a single-leg plan routes exactly one leg', () async {
    mockRoute(200, roadRoute);

    final route = await container.read(
      multiLegRouteProvider(const RoutePlan(
        fromLat: 9.9281,
        fromLng: -84.0907,
        toLat: 9.94,
        toLng: -84.10,
      )).future,
    );

    expect(routeRequests, hasLength(1));
    expect(route.polyline, hasLength(3));
  });

  test('an is_estimate leg makes the whole preview an estimate', () async {
    mockRoute(200, (options) => roadRoute(options, estimate: true));

    final route = await container.read(multiLegRouteProvider(plan).future);

    expect(route.isEstimate, isTrue);
    // The API geometry is kept — never replaced by a client straight line.
    expect(route.polyline, hasLength(5));
  });

  test('any failed leg fails the whole preview (no partial polyline)',
      () async {
    mockRoute(500, (_) => {
          'error': {'code': 'INTERNAL', 'message': 'failed to calculate route'},
        });

    await expectLater(
      container.read(multiLegRouteProvider(plan).future),
      throwsA(isA<DioException>()),
    );
  });

  test('a leg that is not a route fails the whole preview', () async {
    mockRoute(200, (_) => {
          'polyline': [
            {'lat': 9.93, 'lng': -84.095},
          ],
          'total_distance_m': 10.0,
          'total_duration_s': 5.0,
          'is_estimate': false,
        });

    await expectLater(
      container.read(multiLegRouteProvider(plan).future),
      throwsA(isA<Exception>()),
    );
  });
}
