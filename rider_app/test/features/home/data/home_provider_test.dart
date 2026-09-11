import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/features/home/data/home_provider.dart';

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
  });
}