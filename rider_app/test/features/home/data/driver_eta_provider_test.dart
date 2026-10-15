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
    }) {
      final rideStatus = switch (status) {
        'driver_arrived' => RideStatus.driverArrived,
        'in_progress' => RideStatus.onTrip,
        _ => RideStatus.driverApproaching,
      };
      return RideState(
        status: rideStatus,
        rideId: 'ride-1',
        driverLocation: DriverLocation(
          driverId: 'driver-1',
          lat: driverLat,
          lng: driverLng,
        ),
        rideData: const {
          'ride_id': 'ride-1',
          'pickup': {'lat': 9.9281, 'lng': -84.0907},
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
  });
}
