import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/driver_eta_provider.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';
import 'package:rider_app/features/home/model/driver.dart';

import '../../../support/fake_websocket_service.dart';

void main() {
  group('DriverEtaNotifier', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late FakeWebSocketService ws;
    late ProviderContainer container;
    late DriverEtaNotifier eta;
    late RideStatusNotifier rideNotifier;
    late DateTime currentTime;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      ws = FakeWebSocketService();
      rideNotifier = RideStatusNotifier(ws);
      currentTime = DateTime(2026, 3, 1, 10, 0, 0);
      container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(apiClient),
          rideStatusProvider.overrideWith((ref) => rideNotifier),
          driverEtaProvider.overrideWith(
            (ref) => DriverEtaNotifier(
              apiClient,
              ref,
              now: () => currentTime,
            ),
          ),
        ],
      );
      eta = container.read(driverEtaProvider.notifier);
    });

    tearDown(() {
      container.dispose();
      ws.disposeController();
    });

    RideState approaching({
      double driverLat = 9.93,
      double driverLng = -84.09,
      String? status = 'accepted',
      String rideId = 'ride-1',
    }) {
      final rideStatus = switch (status) {
        'driver_arrived' => RideStatus.driverArrived,
        'in_progress' => RideStatus.onTrip,
        'no_driver_available' => RideStatus.noDriverAvailable,
        _ => RideStatus.driverApproaching,
      };
      return RideState(
        status: rideStatus,
        rideId: rideId,
        driverLocation: DriverLocation(
          driverId: 'driver-1',
          lat: driverLat,
          lng: driverLng,
        ),
        rideData: {
          'ride_id': rideId,
          'pickup': const {'lat': 9.9281, 'lng': -84.0907},
        },
      );
    }

    test('the first fix computes once and writes RideState.etaSeconds', () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 240,
          'distance_meters': 2300,
          'is_estimate': false,
        }),
      );

      eta.onRideState(approaching());
      await eta.pendingCompute;

      expect(eta.state.computations, 1);
      expect(eta.state.etaSeconds, 240);
      expect(eta.state.distanceM, 2300);
      final rideState = container.read(rideStatusProvider);
      expect(rideState.etaSeconds, 240);
      expect(rideState.etaDistanceM, 2300);
    });

    test('a second fix inside the interval is throttled', () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 240,
          'distance_meters': 2300,
          'is_estimate': false,
        }),
      );

      eta.onRideState(approaching());
      await eta.pendingCompute;

      // Moved well past the threshold, but only just requested.
      eta.onRideState(approaching(driverLat: 9.95, driverLng: -84.12));
      await eta.pendingCompute;

      expect(eta.state.computations, 1, reason: 'inside the 5 s floor');
    });

    test('a >=150 m move after the floor triggers an early request', () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 240,
          'distance_meters': 2300,
          'is_estimate': false,
        }),
      );

      eta.onRideState(approaching());
      await eta.pendingCompute;

      currentTime = currentTime.add(const Duration(seconds: 6));
      eta.onRideState(approaching(driverLat: 9.95, driverLng: -84.12));
      await eta.pendingCompute;

      expect(eta.state.computations, 2);
    });

    test('a failed compute keeps the previous ETA', () async {
      final failing = ApiClient(baseUrl: 'http://localhost:8080');
      final failingAdapter = DioAdapter(dio: failing.dio);
      failingAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'routing failed'},
        }),
      );
      final failingRide = RideStatusNotifier(ws);
      // Seed a prior value (the accept-time number the failed compute must keep).
      failingRide.applyLiveEta(240, distanceM: 2300);
      final failingContainer = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(failing),
          rideStatusProvider.overrideWith((ref) => failingRide),
          driverEtaProvider.overrideWith(
            (ref) => DriverEtaNotifier(failing, ref, now: () => currentTime),
          ),
        ],
      );
      addTearDown(failingContainer.dispose);
      final failingEta = failingContainer.read(driverEtaProvider.notifier);
      failingEta.onRideState(approaching());
      await failingEta.pendingCompute;

      // `applyLiveEta` is never called on failure, so the value is untouched.
      expect(failingRide.state.etaSeconds, 240);
      expect(failingEta.state.error, isNotNull);
      expect(failingEta.state.computations, 0);
    });

    test('a failed compute is floored: no retry inside 5 s, retry after', () async {
      final failing = ApiClient(baseUrl: 'http://localhost:8080');
      final failingAdapter = DioAdapter(dio: failing.dio);
      var etaRequests = 0;
      failing.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path == '/api/v1/geo/eta') etaRequests++;
            handler.next(options);
          },
        ),
      );
      failingAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'routing failed'},
        }),
      );
      final failingRide = RideStatusNotifier(ws);
      final failingContainer = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(failing),
          rideStatusProvider.overrideWith((ref) => failingRide),
          driverEtaProvider.overrideWith(
            (ref) => DriverEtaNotifier(failing, ref, now: () => currentTime),
          ),
        ],
      );
      addTearDown(failingContainer.dispose);
      final failingEta = failingContainer.read(driverEtaProvider.notifier);

      // First fix fails, and nothing was requested before it — it is immediate.
      failingEta.onRideState(approaching());
      await failingEta.pendingCompute;
      expect(etaRequests, 1);
      expect(failingEta.state.error, isNotNull);
      expect(failingEta.state.computations, 0);

      // A fix inside the floor must NOT re-request just because no success ever
      // set `_referenceFix`; the failed attempt already burned the floor.
      failingEta.onRideState(approaching(driverLat: 9.95, driverLng: -84.12));
      await failingEta.pendingCompute;
      expect(
        etaRequests,
        1,
        reason: 'a failed compute still holds the 5 s floor',
      );

      // After the floor a fix does retry.
      currentTime = currentTime.add(const Duration(seconds: 6));
      failingEta.onRideState(approaching(driverLat: 9.96, driverLng: -84.13));
      await failingEta.pendingCompute;
      expect(etaRequests, 2);
    });

    test('the unknown placeholder is never written', () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 300,
          'distance_meters': 0,
          'is_estimate': false,
        }),
      );

      eta.onRideState(approaching());
      await eta.pendingCompute;

      // It did compute, but refused to write the `300` placeholder.
      expect(eta.state.computations, 1);
      expect(container.read(rideStatusProvider).etaSeconds, isNull);
    });

    test('no compute while on trip or already arrived', () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 240,
          'distance_meters': 2300,
          'is_estimate': false,
        }),
      );

      eta.onRideState(approaching(status: 'in_progress'));
      eta.onRideState(approaching(status: 'driver_arrived'));

      expect(eta.state.computations, 0);
      expect(eta.isPolling, isFalse);
    });

    test('start is idempotent and stop cancels the tick', () {
      eta.start();
      eta.start();
      expect(eta.isPolling, isTrue);

      eta.stop();
      expect(eta.isPolling, isFalse);
      eta.stop();
      expect(eta.isPolling, isFalse);
    });

    test('leaving driverApproaching stops the tick', () {
      eta.onRideState(approaching());
      expect(eta.isPolling, isTrue);

      eta.onRideState(approaching(status: 'in_progress'));
      expect(eta.isPolling, isFalse);
    });

    test(
        'a second ride computes immediately despite the previous ride state '
        '(bug #30)', () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 240,
          'distance_meters': 2300,
          'is_estimate': false,
        }),
      );

      // Ride 1: the first fix computes and sets both `_referenceFix` and the
      // 5 s floor's `_lastRequestAt`.
      eta.onRideState(approaching());
      await eta.pendingCompute;
      expect(eta.state.computations, 1);

      // Leave the trip. This must not leak the per-ride throttle bookkeeping.
      eta.onRideState(approaching(status: 'in_progress'));
      expect(eta.isPolling, isFalse);

      // Ride 2: a different `rideId`, the same simulated wall clock (inside the
      // 5 s floor), and <150 m from ride 1's last fix — so both the floor and the
      // movement trigger would suppress the request if the state leaked.
      eta.onRideState(
        approaching(rideId: 'ride-2', driverLat: 9.9301, driverLng: -84.0901),
      );
      await eta.pendingCompute;

      expect(
        eta.state.computations,
        2,
        reason: 'a new ride must not inherit the previous ride throttle',
      );
    });

    test(
        'a terminal status resets the throttle for the next ride (bug #30)',
        () async {
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.reply(200, {
          'eta_seconds': 240,
          'distance_meters': 2300,
          'is_estimate': false,
        }),
      );

      eta.onRideState(approaching());
      await eta.pendingCompute;
      expect(eta.state.computations, 1);

      // Terminal leave (not just any non-approaching status).
      eta.onRideState(approaching(status: 'no_driver_available'));
      expect(eta.isPolling, isFalse);

      eta.onRideState(
        approaching(rideId: 'ride-2', driverLat: 9.9301, driverLng: -84.0901),
      );
      await eta.pendingCompute;

      expect(
        eta.state.computations,
        2,
        reason: 'a terminal status must not leak the throttle into ride 2',
      );
    });

    test(
        'a stale in-flight response cannot leak into the next ride '
        '(bug #30 residual)', () async {
      // Each `/geo/eta` request hangs on its own completer so the test owns the
      // exact ordering: ride 1's request is left in flight across the ride
      // boundary while ride 2's is launched.
      final pending = <Completer<Map<String, dynamic>>>[];
      dioAdapter.onGet(
        '/api/v1/geo/eta',
        (server) => server.replyCallbackAsync(200, (options) {
          final completer = Completer<Map<String, dynamic>>();
          pending.add(completer);
          return completer.future;
        }),
      );

      Future<void> waitForRequests(int count) async {
        for (var i = 0; i < 100 && pending.length < count; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(pending.length, count, reason: 'expected $count /geo/eta calls');
      }

      // Ride 1: the first fix launches a request we deliberately leave in
      // flight across the boundary.
      eta.onRideState(approaching(rideId: 'ride-1'));
      final ride1Compute = eta.pendingCompute;
      await waitForRequests(1);

      // Boundary: leave `driverApproaching` *before* ride 1's request resolves.
      eta.onRideState(approaching(status: 'in_progress'));

      // Ride 2: a different rideId, the same simulated clock, and <150 m from
      // ride 1's fix — so the stale `_inFlight` guard, the previous ride's
      // floor and the movement trigger would each suppress the request.
      eta.onRideState(
        approaching(rideId: 'ride-2', driverLat: 9.9301, driverLng: -84.0901),
      );
      await waitForRequests(2);
      final ride2Compute = eta.pendingCompute;

      // Resolve ride 1's request *after* ride 2's is already in flight. It is
      // stale, so it must not re-set `_referenceFix` nor write into ride 2.
      pending[0].complete({
        'eta_seconds': 111,
        'distance_meters': 1000,
        'is_estimate': false,
      });
      await ride1Compute;
      expect(
        container.read(rideStatusProvider).etaSeconds,
        isNull,
        reason: 'the stale response must not write the next ride state',
      );
      expect(
        eta.state.computations,
        0,
        reason: 'a stale response does not count as a compute',
      );

      // Resolve ride 2's request: current, so it applies.
      pending[1].complete({
        'eta_seconds': 222,
        'distance_meters': 2000,
        'is_estimate': false,
      });
      await ride2Compute;
      expect(eta.state.computations, 1);
      expect(container.read(rideStatusProvider).etaSeconds, 222);
    });
  });
}
