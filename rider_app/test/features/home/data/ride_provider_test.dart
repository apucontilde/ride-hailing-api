import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/ride_provider.dart';
import 'package:rider_app/features/home/model/fare.dart';

/// A `GET /rides/{id}` body with every field the backend actually returns
/// (`internal/model/ride.go`).
Map<String, dynamic> rideJson({
  String id = 'ride-1',
  String status = 'completed',
  double totalFare = 2870.5,
}) {
  return {
    'id': id,
    'rider_id': 'rider-1',
    'driver_id': 'driver-1',
    'status': status,
    'pickup_lat': 9.9281,
    'pickup_lng': -84.0907,
    'dropoff_lat': 9.94,
    'dropoff_lng': -84.1,
    'pickup_address': 'Main St',
    'dropoff_address': 'Airport Rd',
    'vehicle_type': 'sedan',
    'cancellation_fee': 0.0,
    'base_fare': 1200.0,
    'distance_fare': 900.0,
    'time_fare': 700.0,
    'surge_multiplier': 1.1,
    'total_fare': totalFare,
    'requested_at': '2026-03-01T10:00:00Z',
    'accepted_at': '2026-03-01T10:02:00Z',
    'driver_arrived_at': '2026-03-01T10:06:00Z',
    'started_at': '2026-03-01T10:07:00Z',
    'completed_at': '2026-03-01T10:30:00Z',
    'cancelled_at': null,
    'created_at': '2026-03-01T10:00:00Z',
    'updated_at': '2026-03-01T10:30:00Z',
  };
}

Map<String, dynamic> receiptJson({double total = 2800.0}) => {
      'receipt': {
        'base_fare': 1200.0,
        'distance_fare': 900.0,
        'time_fare': 700.0,
        'surge_multiplier': 1.25,
        'total': total,
      },
    };

void main() {
  group('RideDetailNotifier.fetchRide', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late RideDetailNotifier notifier;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      notifier = RideDetailNotifier(apiClient);
      addTearDown(notifier.dispose);
    });

    test('parses the ride object, including the fare block', () async {
      dioAdapter.onGet(
        '/api/v1/rides/ride-1',
        (server) => server.reply(200, {'ride': rideJson()}),
      );

      final detail = await notifier.fetchRide('ride-1');

      expect(detail, isNotNull);
      expect(detail!.id, 'ride-1');
      expect(detail.status, 'completed');
      expect(detail.driverId, 'driver-1');
      expect(detail.pickupAddress, 'Main St');
      expect(detail.dropoffAddress, 'Airport Rd');
      expect(detail.vehicleType, 'sedan');
      expect(detail.completedAt, '2026-03-01T10:30:00Z');
      expect(detail.cancelledAt, isNull);
      // `total_fare` on the ride object maps onto Fare.total, so the same type
      // serves the ride detail and the receipt.
      expect(detail.fare.baseFare, 1200.0);
      expect(detail.fare.distanceFare, 900.0);
      expect(detail.fare.timeFare, 700.0);
      expect(detail.fare.surgeMultiplier, 1.1);
      expect(detail.fare.total, 2870.5);
      expect(detail.hasFare, isTrue);
      expect(notifier.state.detail, isNotNull);
      expect(notifier.state.loading, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('an unpriced ride reports hasFare false so it cannot clobber a fare',
        () async {
      dioAdapter.onGet(
        '/api/v1/rides/ride-1',
        (server) => server.reply(
          200,
          {'ride': rideJson(status: 'pending', totalFare: 0)},
        ),
      );

      final detail = await notifier.fetchRide('ride-1');

      expect(detail!.hasFare, isFalse);
      expect(detail.fare.total, 0);
    });

    test('a 404 surfaces the backend message and keeps detail null', () async {
      dioAdapter.onGet(
        '/api/v1/rides/nope',
        (server) => server.reply(
          404,
          {
            'error': {'code': 'NOT_FOUND', 'message': 'ride not found'},
          },
        ),
      );

      final detail = await notifier.fetchRide('nope');

      expect(detail, isNull);
      expect(notifier.state.error, 'ride not found');
      expect(notifier.state.detail, isNull);
      expect(notifier.state.loading, isFalse);
    });

    test('a 200 without a ride object reports not found', () async {
      dioAdapter.onGet(
        '/api/v1/rides/ride-1',
        (server) => server.reply(200, {'ride': null}),
      );

      final detail = await notifier.fetchRide('ride-1');

      expect(detail, isNull);
      expect(notifier.state.error, 'Ride not found');
    });
  });

  group('RideDetailNotifier.fetchReceipt', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late RideDetailNotifier notifier;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      notifier = RideDetailNotifier(apiClient);
      addTearDown(notifier.dispose);
    });

    test('parses the five-number breakdown', () async {
      dioAdapter.onGet(
        '/api/v1/rides/ride-1/receipt',
        (server) => server.reply(200, receiptJson()),
      );

      final fare = await notifier.fetchReceipt('ride-1');

      expect(fare, isNotNull);
      expect(fare!.baseFare, 1200.0);
      expect(fare.distanceFare, 900.0);
      expect(fare.timeFare, 700.0);
      expect(fare.surgeMultiplier, 1.25);
      expect(fare.total, 2800.0);
      expect(notifier.state.receipt, isNotNull);
      expect(notifier.state.error, isNull);
    });

    test('a 404 receipt surfaces the backend message and returns null',
        () async {
      dioAdapter.onGet(
        '/api/v1/rides/nope/receipt',
        (server) => server.reply(
          404,
          {
            'error': {'code': 'NOT_FOUND', 'message': 'ride not found'},
          },
        ),
      );

      expect(await notifier.fetchReceipt('nope'), isNull);
      expect(notifier.state.error, 'ride not found');
    });

    test('resolveFare prefers the WS fare and never hits the receipt endpoint',
        () async {
      var receiptCalls = 0;
      dioAdapter.onGet('/api/v1/rides/ride-1/receipt', (server) {
        return server.replyCallback(200, (_) {
          receiptCalls++;
          return receiptJson(total: 1.0);
        });
      });

      final fare = await notifier.resolveFare(
        'ride-1',
        wsFare: Fare(total: 99.0, baseFare: 9.0),
      );

      expect(fare!.total, 99.0);
      expect(receiptCalls, 0,
          reason: 'the WS fare must short-circuit the receipt read');
      expect(notifier.state.receipt, isNull);
    });

    test('resolveFare falls back to GET /rides/{id}/receipt', () async {
      var receiptCalls = 0;
      dioAdapter.onGet('/api/v1/rides/ride-1/receipt', (server) {
        return server.replyCallback(200, (_) {
          receiptCalls++;
          return receiptJson();
        });
      });

      final fare = await notifier.resolveFare('ride-1');

      expect(fare!.total, 2800.0);
      expect(receiptCalls, 1);
    });

    test('a second resolveFare reuses the cached receipt', () async {
      var receiptCalls = 0;
      dioAdapter.onGet('/api/v1/rides/ride-1/receipt', (server) {
        return server.replyCallback(200, (_) {
          receiptCalls++;
          return receiptJson();
        });
      });

      await notifier.resolveFare('ride-1');
      await notifier.resolveFare('ride-1');

      expect(receiptCalls, 1);
    });
  });

  group('RideDetailNotifier.rateRide', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late RideDetailNotifier notifier;
    late List<Map<String, dynamic>> postedBodies;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      notifier = RideDetailNotifier(apiClient);
      postedBodies = [];
      // `data: Matchers.any` is required: `FullHttpRequestMatcher` compares the
      // body against the registered expectation, and a body-carrying POST never
      // matches a route registered without one. The real body is asserted from
      // the captured `RequestOptions` below instead.
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/rate',
        (server) => server.replyCallback(200, (RequestOptions options) {
          postedBodies.add(options.data as Map<String, dynamic>);
          return {'message': 'rating submitted'};
        }),
        data: Matchers.any,
      );
      addTearDown(notifier.dispose);
    });

    test('posts the score and comment and records the ride as rated', () async {
      await notifier.rateRide('ride-1', 5, comment: 'Great driver');

      expect(postedBodies, hasLength(1));
      expect(postedBodies.single['score'], 5);
      expect(postedBodies.single['comment'], 'Great driver');
      expect(notifier.state.rating, RatingOutcome.submitted);
      expect(notifier.state.isRating, isFalse);
      expect(notifier.state.error, isNull);
      expect(notifier.state.ratedRideIds, contains('ride-1'));
      expect(notifier.state.canRate('ride-1'), isFalse);
    });

    test('a second submit while one is in flight never reaches the server',
        () async {
      final gate = Completer<void>();
      var calls = 0;
      dioAdapter.onPost('/api/v1/rides/ride-1/rate', (server) {
        return server.replyCallbackAsync(200, (_) async {
          calls++;
          await gate.future;
          return {'message': 'rating submitted'};
        });
      }, data: Matchers.any);

      final first = notifier.rateRide('ride-1', 5);
      // Not awaited: this is the double-tap. `isRating` is already true.
      expect(notifier.state.isRating, isTrue);
      final dropped = await notifier.rateRide('ride-1', 1);
      gate.complete();
      await first;

      expect(calls, 1, reason: 'the second rateRide must be dropped');
      expect(dropped, RatingOutcome.none,
          reason: 'a dropped submit must not claim an outcome');
      expect(notifier.state.rating, RatingOutcome.submitted);
      expect(notifier.state.ratedRideIds, contains('ride-1'));
    });

    test('a ride already in the seeded set is never re-sent', () async {
      notifier.seedRatedRideIds({'ride-1'});

      expect(notifier.state.canRate('ride-1'), isFalse);
      final outcome = await notifier.rateRide('ride-1', 5);

      expect(outcome, RatingOutcome.alreadyRated);
      expect(postedBodies, isEmpty,
          reason: 'the already-rated set must short-circuit the POST');
      expect(notifier.state.rating, RatingOutcome.alreadyRated);
      expect(notifier.state.ratingRideId, 'ride-1');
      expect(notifier.state.isRating, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('a 409 conflict is swallowed as already rated, not a failure',
        () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-9/rate',
        (server) => server.reply(
          409,
          {
            'error': {'code': 'CONFLICT', 'message': 'ride already rated'},
          },
        ),
        data: Matchers.any,
      );

      await notifier.rateRide('ride-9', 4);

      expect(notifier.state.rating, RatingOutcome.alreadyRated);
      expect(notifier.state.error, isNull);
      expect(notifier.state.isRating, isFalse);
      expect(notifier.state.ratedRideIds, contains('ride-9'));
    });

    test('a real failure is surfaced, not swallowed', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-7/rate',
        (server) => server.reply(
          400,
          {
            'error': {'code': 'BAD_REQUEST', 'message': 'invalid rating'},
          },
        ),
        data: Matchers.any,
      );

      await notifier.rateRide('ride-7', 9);

      expect(notifier.state.rating, RatingOutcome.failed);
      expect(notifier.state.error, 'invalid rating');
      expect(notifier.state.isRating, isFalse);
      expect(notifier.state.ratedRideIds, isNot(contains('ride-7')));
    });

    test('seedRatedRideIds merges and leaves other rides still ratable', () {
      notifier.seedRatedRideIds({'ride-1'});

      expect(notifier.state.canRate('ride-1'), isFalse);
      expect(notifier.state.canRate('ride-2'), isTrue);

      notifier.seedRatedRideIds({'ride-2'});

      expect(notifier.state.ratedRideIds, {'ride-1', 'ride-2'});
    });

    test('rating one ride leaves every other ride ratable [FIX-C]', () async {
      expect(notifier.state.canRate('ride-1'), isTrue);
      expect(notifier.state.canRate('ride-2'), isTrue);

      final outcome = await notifier.rateRide('ride-1', 5);

      expect(outcome, RatingOutcome.submitted);
      expect(notifier.state.canRate('ride-1'), isFalse);
      // `rating` is now `submitted` session-wide, which is exactly what used to
      // gate ride-2. The check must stay ride-scoped.
      expect(notifier.state.rating, RatingOutcome.submitted);
      expect(notifier.state.canRate('ride-2'), isTrue,
          reason: 'FIX-C: a submitted rating must not gate a different ride');
      expect(notifier.state.ratedRideIds, {'ride-1'});
      expect(notifier.state.ratingRideId, 'ride-1');
    });

    test('a 409 for one ride marks only that ride [FIX-C]', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-9/rate',
        (server) => server.reply(
          409,
          {
            'error': {'code': 'CONFLICT', 'message': 'ride already rated'},
          },
        ),
        data: Matchers.any,
      );

      final outcome = await notifier.rateRide('ride-9', 4);

      expect(outcome, RatingOutcome.alreadyRated);
      expect(notifier.state.canRate('ride-9'), isFalse);
      expect(notifier.state.canRate('ride-10'), isTrue,
          reason: 'FIX-C: a conflict on one ride must not gate another');
      expect(notifier.state.ratedRideIds, {'ride-9'});
      expect(notifier.state.ratingRideId, 'ride-9');
    });

    test('the returned outcome belongs to the ride just rated', () async {
      dioAdapter.onPost(
        '/api/v1/rides/ride-2/rate',
        (server) => server.reply(200, {'message': 'rating submitted'}),
        data: Matchers.any,
      );

      final first = await notifier.rateRide('ride-1', 5);
      final second = await notifier.rateRide('ride-2', 3);

      expect(first, RatingOutcome.submitted);
      expect(second, RatingOutcome.submitted);
      expect(notifier.state.ratingRideId, 'ride-2',
          reason: 'the transient outcome tracks the ride that produced it');
      expect(notifier.state.ratedRideIds, {'ride-1', 'ride-2'});
    });
  });

  group('riderRatedRideIdsProvider', () {
    test('reads the ride ids out of the paginated ratings envelope',
        () async {
      final apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      final dioAdapter = DioAdapter(dio: apiClient.dio);
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
            {
              'id': 'r2',
              'ride_id': 'ride-2',
              'rater_role': 'rider',
              'score': 3,
              'comment': 'ok',
              'created_at': '2026-03-02T11:00:00Z',
            },
          ],
          'total': 2,
          'page': 1,
          'per_page': 50,
          'total_pages': 1,
        }),
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      addTearDown(container.dispose);

      final rated = await container.read(riderRatedRideIdsProvider.future);

      expect(rated, {'ride-1', 'ride-2'});
    });

    test('an empty history yields an empty set', () async {
      final apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      final dioAdapter = DioAdapter(dio: apiClient.dio);
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
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      addTearDown(container.dispose);

      expect(await container.read(riderRatedRideIdsProvider.future), isEmpty);
    });

    test('walks every page so a rating past page 1 is not missed [FIX-D]',
        () async {
      final apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      final dioAdapter = DioAdapter(dio: apiClient.dio);
      final requestedPages = <int>[];
      dioAdapter.onGet('/api/v1/rider/ratings', (server) {
        return server.replyCallback(200, (options) {
          final page = int.parse(options.queryParameters['page'].toString());
          requestedPages.add(page);
          if (page == 1) {
            return {
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
              'total': 2,
              'page': 1,
              'per_page': 50,
              'total_pages': 2,
            };
          }
          return {
            'ratings': [
              {
                'id': 'r2',
                'ride_id': 'ride-51',
                'rater_role': 'rider',
                'score': 4,
                'comment': '',
                'created_at': '2026-02-01T11:00:00Z',
              },
            ],
            'total': 2,
            'page': 2,
            'per_page': 50,
            'total_pages': 2,
          };
        });
      });
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      addTearDown(container.dispose);

      final rated = await container.read(riderRatedRideIdsProvider.future);

      expect(requestedPages, [1, 2]);
      expect(rated, {'ride-1', 'ride-51'});
    });

    test('a lying total_pages cannot make the seed walk unbounded [FIX-D]',
        () async {
      final apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      final dioAdapter = DioAdapter(dio: apiClient.dio);
      var calls = 0;
      dioAdapter.onGet('/api/v1/rider/ratings', (server) {
        return server.replyCallback(200, (_) {
          calls++;
          return {
            'ratings': <dynamic>[],
            'total': 999999,
            'page': calls,
            'per_page': 50,
            'total_pages': 999999,
          };
        });
      });
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      addTearDown(container.dispose);

      await container.read(riderRatedRideIdsProvider.future);

      expect(calls, ratedRideIdsMaxPages);
    });
  });
}
