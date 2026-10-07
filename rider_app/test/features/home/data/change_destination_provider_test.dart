import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/features/home/data/change_destination_provider.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';

void main() {
  group('isDestinationChangeable', () {
    test('is true for exactly the API-changeable statuses', () {
      expect(isDestinationChangeable(RideStatus.matching), isTrue);
      expect(isDestinationChangeable(RideStatus.driverApproaching), isTrue);
      expect(isDestinationChangeable(RideStatus.driverArrived), isTrue);
      expect(isDestinationChangeable(RideStatus.onTrip), isTrue);
    });

    test('is false for terminal / non-changeable statuses', () {
      expect(isDestinationChangeable(RideStatus.completed), isFalse);
      expect(isDestinationChangeable(RideStatus.cancelled), isFalse);
      expect(isDestinationChangeable(RideStatus.noDriverAvailable), isFalse);
      expect(isDestinationChangeable(RideStatus.idle), isFalse);
    });
  });

  group('ChangeDestinationNotifier', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late ChangeDestinationNotifier notifier;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(
        dio: apiClient.dio,
        matcher: const UrlRequestMatcher(matchMethod: true),
      );
      notifier = ChangeDestinationNotifier(apiClient);
    });

    tearDown(() => notifier.dispose());

    void mockPut(int status, Object body,
        {void Function(RequestOptions)? capture}) {
      dioAdapter.onPut(
        '/api/v1/rides/ride-1/destination',
        (server) => server.replyCallback(status, (options) {
          capture?.call(options);
          return body;
        }),
      );
    }

    test('PUTs lat/lng/address and reports success', () async {
      Map<String, dynamic>? sent;
      mockPut(
        200,
        {'ride': {'id': 'ride-1', 'status': 'in_progress'}},
        capture: (options) => sent = options.data as Map<String, dynamic>,
      );

      final ok = await notifier.changeDestination(
        'ride-1',
        lat: 9.96,
        lng: -84.13,
        address: 'New Place',
      );

      expect(ok, isTrue);
      expect(notifier.state.succeeded, isTrue);
      expect(notifier.state.error, isNull);
      expect(notifier.state.isSubmitting, isFalse);
      expect(sent, {'lat': 9.96, 'lng': -84.13, 'address': 'New Place'});
    });

    test('409 surfaces the API message verbatim', () async {
      mockPut(409, {
        'error': {
          'code': 'CONFLICT',
          'message': 'destination can no longer be changed',
        },
      });

      final ok = await notifier.changeDestination(
        'ride-1',
        lat: 9.96,
        lng: -84.13,
        address: 'New Place',
      );

      expect(ok, isFalse);
      expect(notifier.state.succeeded, isFalse);
      expect(notifier.state.error, 'destination can no longer be changed');
    });

    test('409 without a body message falls back to the locked copy', () async {
      mockPut(409, {
        'error': {'message': ''},
      });

      await notifier.changeDestination(
        'ride-1',
        lat: 9.96,
        lng: -84.13,
        address: 'New Place',
      );

      expect(notifier.state.error, 'Destination can no longer be changed');
    });

    test('404 surfaces the API message verbatim', () async {
      mockPut(404, {
        'error': {'code': 'NOT_FOUND', 'message': 'This ride could not be found'},
      });

      final ok = await notifier.changeDestination(
        'ride-1',
        lat: 9.96,
        lng: -84.13,
        address: 'New Place',
      );

      expect(ok, isFalse);
      expect(notifier.state.error, 'This ride could not be found');
    });

    test('404 without a body message falls back to the not-found copy',
        () async {
      mockPut(404, {
        'error': {'message': ''},
      });

      await notifier.changeDestination(
        'ride-1',
        lat: 9.96,
        lng: -84.13,
        address: 'New Place',
      );

      expect(notifier.state.error, 'This ride could not be found');
    });

    test('reset clears the surfaceable state', () async {
      mockPut(409, {
        'error': {'message': 'destination can no longer be changed'},
      });
      await notifier.changeDestination(
        'ride-1',
        lat: 9.96,
        lng: -84.13,
        address: 'New Place',
      );
      expect(notifier.state.error, isNotNull);

      notifier.reset();

      expect(notifier.state.error, isNull);
      expect(notifier.state.succeeded, isFalse);
      expect(notifier.state.isSubmitting, isFalse);
    });
  });
}
