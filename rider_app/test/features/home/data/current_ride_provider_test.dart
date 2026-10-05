import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/features/home/data/current_ride_provider.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';

void main() {
  group('CurrentRideNotifier', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late ProviderContainer container;
    late CurrentRideNotifier notifier;
    late DateTime currentTime;
    Map<String, dynamic> payload = {'ride': null};

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.replyCallback(
          200,
          (requestOptions) => Map<String, dynamic>.from(payload),
        ),
      );
      currentTime = DateTime(2026, 1, 1, 12, 0, 0);
      container = ProviderContainer(
        overrides: [
          currentRideProvider.overrideWith(
            (ref) => CurrentRideNotifier(
              apiClient,
              ref,
              now: () => currentTime,
            ),
          ),
        ],
      );
      notifier = container.read(currentRideProvider.notifier);
      addTearDown(container.dispose);
    });

    test('initial state is idle with no ride', () {
      expect(notifier.state.loading, isFalse);
      expect(notifier.state.rideId, isNull);
      expect(notifier.state.noDriverAvailable, isFalse);
      expect(notifier.state.stillSearching, isFalse);
      expect(notifier.state.needsRestore, isFalse);
    });

    test('no_driver_available status sets the no driver state', () async {
      payload = {'ride': {'id': 'ride-1', 'status': 'no_driver_available'}};

      await notifier.pollNow();

      expect(notifier.state.noDriverAvailable, isTrue);
      expect(notifier.state.status, 'no_driver_available');
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.stillSearching, isFalse);
    });

    test('cancelled stops the poll', () async {
      payload = {'ride': {'id': 'ride-c', 'status': 'cancelled'}};

      notifier.startPolling();
      await notifier.pollNow();

      expect(notifier.state.status, 'cancelled');
      expect(notifier.isPolling, isFalse);
    });

    test('completed stops the poll', () async {
      payload = {'ride': {'id': 'ride-d', 'status': 'completed'}};

      notifier.startPolling();
      await notifier.pollNow();

      expect(notifier.state.status, 'completed');
      expect(notifier.isPolling, isFalse);
    });

    test('no_driver_available stops the poll', () async {
      payload = {'ride': {'id': 'ride-e', 'status': 'no_driver_available'}};

      notifier.startPolling();
      await notifier.pollNow();

      expect(notifier.isPolling, isFalse);
    });

    test('non-terminal statuses keep the poll running', () async {
      for (final status in ['pending', 'accepted', 'in_progress']) {
        payload = {'ride': {'id': 'ride-$status', 'status': status}};

        notifier.startPolling();
        await notifier.pollNow();

        expect(
          notifier.isPolling,
          isTrue,
          reason: '$status must keep polling',
        );
        notifier.stopPolling();
      }
    });

    test('active statuses restore into ride_status_provider', () async {
      payload = {'ride': {'id': 'ride-2', 'status': 'accepted'}};

      await notifier.pollNow();

      final rideState = container.read(rideStatusProvider);
      expect(rideState.status, RideStatus.driverApproaching);
      expect(rideState.rideId, 'ride-2');
      expect(notifier.state.needsRestore, isTrue);
      expect(notifier.state.status, 'accepted');
    });

    test('in_progress restores into onTrip and needsRestore', () async {
      payload = {'ride': {'id': 'ride-3', 'status': 'in_progress'}};

      await notifier.pollNow();

      final rideState = container.read(rideStatusProvider);
      expect(rideState.status, RideStatus.onTrip);
      expect(rideState.rideId, 'ride-3');
      expect(notifier.state.needsRestore, isTrue);
    });

    test('a pending ride that disappears becomes no driver available', () async {
      payload = {'ride': {'id': 'ride-1', 'status': 'pending'}};
      await notifier.pollNow();

      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.status, 'pending');
      expect(notifier.state.noDriverAvailable, isFalse);

      payload = {'ride': null};
      await notifier.pollNow();

      expect(notifier.state.noDriverAvailable, isTrue);
      expect(notifier.state.status, 'no_driver_available');
      expect(notifier.state.stillSearching, isFalse);
    });

    test('null ride stays searching until the 30s threshold', () async {
      payload = {'ride': null};
      notifier.startPolling();
      notifier.stopPolling();
      await notifier.pollNow();

      expect(notifier.state.stillSearching, isFalse);

      currentTime = currentTime.add(const Duration(seconds: 31));
      await notifier.pollNow();

      expect(notifier.state.stillSearching, isTrue);
      expect(notifier.state.noDriverAvailable, isFalse);
    });

    test('network error surfaces an error without flagging no driver', () async {
      final failingApi = ApiClient(baseUrl: 'http://localhost:8080');
      final failingAdapter = DioAdapter(dio: failingApi.dio);
      failingAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.reply(500, {'message': 'Server error'}),
      );
      final failingContainer = ProviderContainer(
        overrides: [
          currentRideProvider.overrideWith(
            (ref) => CurrentRideNotifier(failingApi, ref),
          ),
        ],
      );
      final failingNotifier = failingContainer.read(currentRideProvider.notifier);
      addTearDown(failingContainer.dispose);

      await failingNotifier.pollNow();

      expect(failingNotifier.state.error, isNotNull);
      expect(failingNotifier.state.noDriverAvailable, isFalse);
      expect(failingNotifier.state.stillSearching, isFalse);
    });
  });
}