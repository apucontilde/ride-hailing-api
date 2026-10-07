import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/home_provider.dart';
import 'package:rider_app/features/home/model/place.dart';

void main() {
  group('RideCreationNotifier.cancelRide', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late RideCreationNotifier notifier;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      notifier = RideCreationNotifier(apiClient);
    });

    tearDown(() {
      notifier.dispose();
    });

    test('cancel success clears isCancelling without error', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.reply(200, {'ride': {'id': 'ride-1', 'status': 'cancelled'}}),
      );

      await notifier.cancelRide('ride-1');

      expect(notifier.state.isCancelling, isFalse);
      expect(notifier.state.cancelError, isNull);
    });

    test('401 maps to UnauthorizedException message', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.reply(401, {'message': 'Invalid token'}),
      );

      await notifier.cancelRide('ride-1');

      expect(notifier.state.isCancelling, isFalse);
      expect(notifier.state.cancelError, 'Invalid token');
    });

    test('409 maps to ConflictException message', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.reply(409, {'message': 'Ride cannot be cancelled'}),
      );

      await notifier.cancelRide('ride-1');

      expect(notifier.state.isCancelling, isFalse);
      expect(notifier.state.cancelError, 'Ride cannot be cancelled');
    });

    test('reset clears cancel state', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.reply(401, {'message': 'Invalid token'}),
      );
      await notifier.cancelRide('ride-1');
      expect(notifier.state.cancelError, isNotNull);

      notifier.reset();

      expect(notifier.state.isCancelling, isFalse);
      expect(notifier.state.cancelError, isNull);
      expect(notifier.state.rideId, isNull);
    });
  });

  group('RideCreationNotifier.createRide', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late RideCreationNotifier notifier;
    late List<String?> keys;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(
        dio: apiClient.dio,
        matcher: const UrlRequestMatcher(matchMethod: true),
      );
      keys = <String?>[];
      apiClient.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            keys.add(options.headers['Idempotency-Key'] as String?);
            handler.next(options);
          },
        ),
      );
      notifier = RideCreationNotifier(apiClient);
    });

    tearDown(() {
      notifier.dispose();
    });

    test('creates a ride and parses the ride id', () async {
      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.reply(201, {'ride': {'id': 'ride-1', 'status': 'pending'}}),
      );

      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.isLoading, isFalse);
      expect(notifier.state.error, isNull);
      expect(keys.last, isNotNull);
    });

    test('reuses the idempotency key after a failure and clears it on success',
        () async {
      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.reply(500, {'message': 'boom'}),
      );
      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      expect(notifier.state.isLoading, isFalse);
      expect(notifier.state.error, isNotNull);
      expect(notifier.state.rideId, isNull);

      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.reply(201, {'ride': {'id': 'ride-2', 'status': 'pending'}}),
      );
      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      expect(notifier.state.rideId, 'ride-2');
      expect(notifier.state.error, isNull);
      expect(keys[0], isNotNull);
      expect(keys[1], keys[0]);

      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.reply(201, {'ride': {'id': 'ride-3', 'status': 'pending'}}),
      );
      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      expect(keys[2], isNot(keys[0]));
    });

    test('resolves a replayed empty body via /rides/current', () async {
      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.reply(201, {}),
      );
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.reply(200, {'ride': {'id': 'ride-9', 'status': 'pending'}}),
      );

      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      expect(notifier.state.rideId, 'ride-9');
      expect(notifier.state.error, isNull);
    });

    test('server error surfaces the mapped error message', () async {
      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.reply(422, {'error': {'message': 'Invalid vehicle type'}}),
      );

      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      expect(notifier.state.error, 'Invalid vehicle type');
      expect(notifier.state.isLoading, isFalse);
      expect(notifier.state.rideId, isNull);
    });

    test('posts the ordered stops array and never sends a kind', () async {
      Map<String, dynamic>? sent;
      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.replyCallback(201, (options) {
          sent = Map<String, dynamic>.from(options.data as Map);
          return {'ride': {'id': 'ride-1', 'status': 'pending'}};
        }),
      );

      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
        stops: const [
          Place(id: 's1', name: 'First', address: 'First St', lat: 9.93, lng: -84.095),
          Place(id: 's2', name: 'Second', address: 'Second St', lat: 9.935, lng: -84.098),
        ],
      );

      // Position is the sequence; the destination stays the top-level dropoff.
      expect(sent!['stops'], [
        {'lat': 9.93, 'lng': -84.095, 'address': 'First St'},
        {'lat': 9.935, 'lng': -84.098, 'address': 'Second St'},
      ]);
      for (final stop in sent!['stops'] as List<dynamic>) {
        expect((stop as Map).containsKey('kind'), isFalse);
        expect(stop.containsKey('sequence'), isFalse);
      }
      expect(sent!['dropoff_lat'], 9.94);
      expect(sent!['dropoff_address'], 'Airport Rd');
    });

    test('omits the stops key entirely when there are none', () async {
      Map<String, dynamic>? sent;
      dioAdapter.onPost(
        '/api/v1/rides',
        (server) => server.replyCallback(201, (options) {
          sent = Map<String, dynamic>.from(options.data as Map);
          return {'ride': {'id': 'ride-1', 'status': 'pending'}};
        }),
      );

      await notifier.createRide(
        pickupLat: 9.9281,
        pickupLng: -84.0907,
        pickupAddress: 'Main St',
        dropoffLat: 9.94,
        dropoffLng: -84.1,
        dropoffAddress: 'Airport Rd',
        vehicleType: 'standard',
      );

      // The single-stop booking payload stays byte-for-byte unchanged.
      expect(sent!.keys.toSet(), {
        'pickup_lat',
        'pickup_lng',
        'pickup_address',
        'dropoff_lat',
        'dropoff_lng',
        'dropoff_address',
        'vehicle_type',
      });
    });
  });

  group('NavigationRoute.fromJson', () {
    test('parses is_estimate false', () {
      final route = NavigationRoute.fromJson({
        'polyline': [{'lat': 9.9, 'lng': -84.1}],
        'total_distance_m': 1000,
        'total_duration_s': 90,
        'is_estimate': false,
      });
      expect(route.isEstimate, isFalse);
    });

    test('parses is_estimate true', () {
      final route = NavigationRoute.fromJson({
        'polyline': [{'lat': 9.9, 'lng': -84.1}],
        'total_distance_m': 500,
        'total_duration_s': 60,
        'is_estimate': true,
      });
      expect(route.isEstimate, isTrue);
    });
  });

  group('placeSearchProvider', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late ProviderContainer container;
    late List<Map<String, dynamic>> requests;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(
        dio: apiClient.dio,
        matcher: const UrlRequestMatcher(matchMethod: true),
      );
      requests = <Map<String, dynamic>>[];
      apiClient.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(Map<String, dynamic>.from(options.queryParameters));
            handler.next(options);
          },
        ),
      );
      container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      addTearDown(container.dispose);
    });

    test('sends a single request with one fixed radius', () async {
      dioAdapter.onGet(
        '/api/v1/places/autocomplete',
        (server) => server.reply(200, {'places': <dynamic>[]}),
      );

      final places = await container.read(placeSearchProvider(
        const PlaceSearchArgs(query: 'cafe', lat: 9.93, lng: -84.08),
      ).future);

      expect(places, isEmpty);
      expect(requests, hasLength(1));
      expect(requests.single['q'], 'cafe');
      expect(requests.single['radius'], 30000.0);
    });

    test('blank query makes no request', () async {
      final places = await container.read(placeSearchProvider(
        const PlaceSearchArgs(query: '   ', lat: 9.93, lng: -84.08),
      ).future);

      expect(places, isEmpty);
      expect(requests, isEmpty);
    });
  });

  group('priceEstimatesProvider', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late ProviderContainer container;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(
        dio: apiClient.dio,
        matcher: const UrlRequestMatcher(matchMethod: true),
      );
      container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      addTearDown(container.dispose);
    });

    test('parses the API total and breakdown fields', () async {
      dioAdapter.onGet(
        '/api/v1/estimates/price',
        (server) => server.reply(200, {
          'estimates': [
            {
              'vehicle_type': 'sedan',
              'base_fare': 2.5,
              'distance_rate': 1.5,
              'time_rate': 0.4,
              'distance_fare': 3.1,
              'time_fare': 0.9,
              'surge_multiplier': 1.2,
              'total': 6.5,
              'region_id': 'cr-sj',
              'currency': 'USD',
              'demand_multiplier': 1.2,
              'supply_multiplier': 1.0,
              'grade_uplift_pct': 0.05,
            }
          ],
        }),
      );

      final estimates = await container.read(priceEstimatesProvider({
        'pickup_lat': 9.93,
        'pickup_lng': -84.08,
        'dropoff_lat': 9.94,
        'dropoff_lng': -84.10,
      }).future);

      expect(estimates, hasLength(1));
      final estimate = estimates.single;
      expect(estimate.total, 6.5);
      expect(estimate.baseFare, 2.5);
      expect(estimate.distanceFare, 3.1);
      expect(estimate.timeFare, 0.9);
      expect(estimate.surgeMultiplier, 1.2);
      expect(estimate.demandMultiplier, 1.2);
      expect(estimate.supplyMultiplier, 1.0);
      expect(estimate.currency, 'USD');
      expect(estimate.gradeUpliftPct, 0.05);
      expect(estimate.formattedTotal, 'USD6.50');
    });
  });
}
