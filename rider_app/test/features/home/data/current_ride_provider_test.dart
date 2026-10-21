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
            (ref) =>
                CurrentRideNotifier(apiClient, ref, now: () => currentTime),
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
      payload = {
        'ride': {'id': 'ride-1', 'status': 'no_driver_available'},
      };

      await notifier.pollNow();

      expect(notifier.state.noDriverAvailable, isTrue);
      expect(notifier.state.status, 'no_driver_available');
      expect(notifier.state.rideId, 'ride-1');
      expect(notifier.state.stillSearching, isFalse);
    });

    test('cancelled stops the poll', () async {
      payload = {
        'ride': {'id': 'ride-c', 'status': 'cancelled'},
      };

      notifier.startPolling();
      await notifier.pollNow();

      expect(notifier.state.status, 'cancelled');
      expect(notifier.isPolling, isFalse);
    });

    test('completed stops the poll', () async {
      payload = {
        'ride': {'id': 'ride-d', 'status': 'completed'},
      };

      notifier.startPolling();
      await notifier.pollNow();

      expect(notifier.state.status, 'completed');
      expect(notifier.isPolling, isFalse);
    });

    test('no_driver_available stops the poll', () async {
      payload = {
        'ride': {'id': 'ride-e', 'status': 'no_driver_available'},
      };

      notifier.startPolling();
      await notifier.pollNow();

      expect(notifier.isPolling, isFalse);
    });

    test('non-terminal statuses keep the poll running', () async {
      for (final status in ['pending', 'accepted', 'in_progress']) {
        payload = {
          'ride': {'id': 'ride-$status', 'status': status},
        };

        notifier.startPolling();
        await notifier.pollNow();

        expect(notifier.isPolling, isTrue, reason: '$status must keep polling');
        notifier.stopPolling();
      }
    });

    test('active statuses restore into ride_status_provider', () async {
      payload = {
        'ride': {'id': 'ride-2', 'status': 'accepted'},
      };

      await notifier.pollNow();

      final rideState = container.read(rideStatusProvider);
      expect(rideState.status, RideStatus.driverApproaching);
      expect(rideState.rideId, 'ride-2');
      expect(notifier.state.needsRestore, isTrue);
      expect(notifier.state.status, 'accepted');
    });

    test('in_progress restores into onTrip and needsRestore', () async {
      payload = {
        'ride': {'id': 'ride-3', 'status': 'in_progress'},
      };

      await notifier.pollNow();

      final rideState = container.read(rideStatusProvider);
      expect(rideState.status, RideStatus.onTrip);
      expect(rideState.rideId, 'ride-3');
      expect(notifier.state.needsRestore, isTrue);
    });

    test('a pending ride needs restore to the matching screen', () async {
      payload = {
        'ride': {'id': 'ride-p', 'status': 'pending'},
      };

      await notifier.pollNow();

      expect(notifier.state.needsRestore, isTrue);
      expect(notifier.state.status, 'pending');
      expect(container.read(rideStatusProvider).status, RideStatus.matching);
    });

    test('completed is not a restore target from /rides/current', () async {
      // The endpoint's query excludes completed rides; it must never restore.
      payload = {
        'ride': {'id': 'ride-done', 'status': 'completed'},
      };

      await notifier.pollNow();

      expect(notifier.state.needsRestore, isFalse);
    });

    test('reset clears the poll view', () async {
      payload = {
        'ride': {'id': 'ride-1', 'status': 'accepted'},
      };
      await notifier.pollNow();
      expect(notifier.state.needsRestore, isTrue);

      notifier.reset();

      expect(notifier.state.rideId, isNull);
      expect(notifier.state.needsRestore, isFalse);
      expect(notifier.state.status, isNull);
    });

    test(
      'a pending ride that disappears becomes no driver available',
      () async {
        payload = {
          'ride': {'id': 'ride-1', 'status': 'pending'},
        };
        await notifier.pollNow();

        expect(notifier.state.rideId, 'ride-1');
        expect(notifier.state.status, 'pending');
        expect(notifier.state.noDriverAvailable, isFalse);

        payload = {'ride': null};
        await notifier.pollNow();

        expect(notifier.state.noDriverAvailable, isTrue);
        expect(notifier.state.status, 'no_driver_available');
        expect(notifier.state.stillSearching, isFalse);
      },
    );

    test('null ride stays searching until the 30s threshold', () async {
      payload = {'ride': null};
      // The first poll seeds the search window; no explicit `startPolling`
      // seed is needed because `pollNow` arms `_startedAt` on its own.
      await notifier.pollNow();

      expect(notifier.state.stillSearching, isFalse);

      currentTime = currentTime.add(const Duration(seconds: 31));
      await notifier.pollNow();

      expect(notifier.state.stillSearching, isTrue);
      expect(notifier.state.noDriverAvailable, isFalse);
    });

    test('the poll cap writes a terminal timeout state', () async {
      payload = {
        'ride': {'id': 'ride-cap', 'status': 'pending'},
      };

      // Arm a real timer so the terminal assertion checks the production stop
      // path, not a timer that was never running. The immediate poll is awaited
      // separately to avoid racing it with the loop below.
      notifier.startPolling(interval: const Duration(hours: 1));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(notifier.isPolling, isTrue);

      // `startPolling` already performed attempt 1; run the remaining attempts.
      for (var i = 1; i < CurrentRideNotifier.maxAttempts; i++) {
        await notifier.pollNow();
      }
      // The cap has not been hit yet: the timer is still armed.
      expect(notifier.isPolling, isTrue);

      await notifier.pollNow();

      expect(notifier.state.searchTimedOut, isTrue);
      expect(notifier.isPolling, isFalse);
      expect(notifier.state.loading, isFalse);
      expect(notifier.state.stillSearching, isFalse);
      // The last real backend status is preserved, not fabricated.
      expect(notifier.state.status, 'pending');
      expect(notifier.state.rideId, 'ride-cap');
      expect(notifier.state.noDriverAvailable, isFalse);
    });

    test('checkOnce after the cap performs a real request', () async {
      final countApi = ApiClient(baseUrl: 'http://localhost:8080');
      final countAdapter = DioAdapter(dio: countApi.dio);
      var requests = 0;
      countAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.replyCallback(200, (_) {
          requests++;
          return {
            'ride': {'id': 'ride-new', 'status': 'accepted'},
          };
        }),
      );
      final countContainer = ProviderContainer(
        overrides: [
          currentRideProvider.overrideWith(
            (ref) => CurrentRideNotifier(countApi, ref),
          ),
        ],
      );
      addTearDown(countContainer.dispose);
      final counting = countContainer.read(currentRideProvider.notifier);

      for (var i = 0; i < CurrentRideNotifier.maxAttempts; i++) {
        await counting.pollNow();
      }
      expect(requests, CurrentRideNotifier.maxAttempts);
      await counting.pollNow();
      expect(counting.state.searchTimedOut, isTrue);
      expect(requests, CurrentRideNotifier.maxAttempts);

      // RED on the old tree: the stale attempt counter made this a no-op.
      await counting.checkOnce();

      expect(requests, CurrentRideNotifier.maxAttempts + 1);
      expect(counting.state.searchTimedOut, isFalse);
      expect(counting.state.status, 'accepted');
      expect(counting.state.rideId, 'ride-new');
    });

    test('startPolling after a timeout clears the flag and polls for real', () async {
      final countApi = ApiClient(baseUrl: 'http://localhost:8080');
      final countAdapter = DioAdapter(dio: countApi.dio);
      var requests = 0;
      countAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.replyCallback(200, (_) {
          requests++;
          return {
            'ride': {'id': 'ride-retry', 'status': 'pending'},
          };
        }),
      );
      final countContainer = ProviderContainer(
        overrides: [
          currentRideProvider.overrideWith(
            (ref) => CurrentRideNotifier(countApi, ref),
          ),
        ],
      );
      addTearDown(countContainer.dispose);
      final retrying = countContainer.read(currentRideProvider.notifier);

      for (var i = 0; i < CurrentRideNotifier.maxAttempts; i++) {
        await retrying.pollNow();
      }
      await retrying.pollNow();
      expect(retrying.state.searchTimedOut, isTrue);
      expect(retrying.isPolling, isFalse);
      final beforeRetry = requests;

      // The real retry path, not a fake: the flag clears and a fresh request
      // runs immediately.
      retrying.startPolling(interval: const Duration(hours: 1));
      expect(retrying.state.searchTimedOut, isFalse);
      expect(retrying.isPolling, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(requests, beforeRetry + 1);
      expect(retrying.state.status, 'pending');
      expect(retrying.state.rideId, 'ride-retry');
      retrying.stopPolling();
    });

    test('checkOnce resets the search window', () async {
      // The one-shot restore must not inherit the previous session's (or the
      // previous poll's) elapsed search time.
      payload = {'ride': null};
      await notifier.pollNow();
      currentTime = currentTime.add(const Duration(seconds: 31));
      await notifier.pollNow();
      expect(notifier.state.stillSearching, isTrue);

      await notifier.checkOnce();

      expect(notifier.state.stillSearching, isFalse);
      expect(notifier.state.noDriverAvailable, isFalse);
    });

    test('checkOnce ignores a stale ride when the server returns null', () async {
      // A warm provider from a previous (or already-ended) session must not be
      // treated as "the tracked ride vanished" by the one-shot restore.
      payload = {
        'ride': {'id': 'ride-old', 'status': 'pending'},
      };
      await notifier.pollNow();
      expect(notifier.state.rideId, 'ride-old');
      expect(notifier.state.status, 'pending');

      payload = {'ride': null};
      await notifier.checkOnce();

      expect(notifier.state.noDriverAvailable, isFalse);
      expect(notifier.state.status, isNull);
      expect(notifier.state.rideId, isNull);
      expect(notifier.state.needsRestore, isFalse);
    });

    test('reset clears attempts, timer and state', () async {
      payload = {
        'ride': {'id': 'ride-1', 'status': 'pending'},
      };

      // A timer armed before the reset must be gone afterwards.
      notifier.startPolling(interval: const Duration(days: 1));
      await notifier.pollNow();
      expect(notifier.isPolling, isTrue);
      notifier.reset();
      expect(notifier.isPolling, isFalse);
      expect(notifier.state.status, isNull);
      expect(notifier.state.rideId, isNull);

      // Exhaust the cap, then reset: the attempt counter must be cleared, so a
      // plain `pollNow` (which never resets it) hits the endpoint again.
      for (var i = 0; i < CurrentRideNotifier.maxAttempts; i++) {
        await notifier.pollNow();
      }
      await notifier.pollNow();
      expect(notifier.state.searchTimedOut, isTrue);

      notifier.reset();
      expect(notifier.state.searchTimedOut, isFalse);
      payload = {
        'ride': {'id': 'ride-r', 'status': 'accepted'},
      };
      await notifier.pollNow();

      expect(notifier.state.needsRestore, isTrue);
      expect(notifier.state.rideId, 'ride-r');
    });

    test(
      'network error surfaces an error without flagging no driver',
      () async {
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
        final failingNotifier = failingContainer.read(
          currentRideProvider.notifier,
        );
        addTearDown(failingContainer.dispose);

        await failingNotifier.pollNow();

        expect(failingNotifier.state.error, isNotNull);
        expect(failingNotifier.state.noDriverAvailable, isFalse);
        expect(failingNotifier.state.stillSearching, isFalse);
      },
    );
  });
}
