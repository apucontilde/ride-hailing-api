import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/data/driver_tracking_provider.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';
import 'package:rider_app/features/home/model/driver.dart';

/// The tracker and the ride-state merge only need the event stream, never a
/// live socket.
class FakeWebSocketService extends WebSocketService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;

  void disposeController() => _controller.close();
}

void main() {
  group('DriverTrackingNotifier', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late FakeWebSocketService ws;
    late ProviderContainer container;
    late DriverTrackingNotifier tracker;
    late RideStatusNotifier rideNotifier;
    /// Set when a test disposes the container itself, so `tearDown` does not do
    /// it twice (Riverpod owns the notifier and would complain).
    bool containerDisposed = false;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(dio: apiClient.dio);
      ws = FakeWebSocketService();
      rideNotifier = RideStatusNotifier(ws);
      container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(apiClient),
          rideStatusProvider.overrideWith((ref) => rideNotifier),
          driverTrackingProvider.overrideWith(
            (ref) => DriverTrackingNotifier(apiClient, ref),
          ),
        ],
      );
      tracker = container.read(driverTrackingProvider.notifier);
      containerDisposed = false;
    });

    tearDown(() {
      if (!containerDisposed) container.dispose();
      ws.disposeController();
    });

    test('a polled fix is folded into RideState.driverLocation', () async {
      dioAdapter.onGet(
        '/api/v1/drivers/driver-1/location',
        (server) => server.reply(200, {
          'driver_id': 'driver-1',
          'lat': 9.9512,
          'lng': -84.1234,
          'heading': 90.0,
          'speed': 14.0,
          'status': 'en_route',
          'updated_at': '2026-03-01T10:10:00Z',
        }),
      );
      tracker.attach('driver-1');

      await tracker.pollNow();

      expect(tracker.state.httpPolls, 1);
      expect(tracker.state.error, isNull);
      final location = container.read(rideStatusProvider).driverLocation;
      expect(location, isNotNull);
      expect(location!.lat, 9.9512);
      expect(location.lng, -84.1234);
      expect(location.heading, 90.0);
      expect(location.speed, 14.0);
      // The HTTP path must not invent an identity the WS stream owns.
      expect(container.read(rideStatusProvider).driver, isNull);
    });

    test('a 404 is surfaced on the state instead of throwing', () async {
      dioAdapter.onGet(
        '/api/v1/drivers/driver-1/location',
        (server) => server.reply(
          404,
          {
            'error': {
              'code': 'NOT_FOUND',
              'message': 'driver location unavailable',
            },
          },
        ),
      );
      tracker.attach('driver-1');

      await tracker.pollNow();

      expect(tracker.state.httpPolls, 1);
      expect(tracker.state.error, 'driver location unavailable');
      expect(container.read(rideStatusProvider).driverLocation, isNull);
    });

    test('no driver id means no request at all', () async {
      var calls = 0;
      dioAdapter.onGet('/api/v1/drivers/driver-1/location', (server) {
        return server.replyCallback(200, (_) {
          calls++;
          return {'driver_id': 'driver-1', 'lat': 1, 'lng': 2};
        });
      });

      await tracker.pollNow();

      expect(calls, 0);
      expect(tracker.state.httpPolls, 0);
    });

    test('noteWsLocation publishes the fix and restarts the silence window',
        () async {
      expect(tracker.silentTicks, 0);

      tracker.noteWsLocation(
        const DriverLocation(driverId: 'driver-1', lat: 1, lng: 2),
      );

      expect(tracker.state.location!.lat, 1);
      expect(tracker.silentTicks, 0);
      expect(tracker.state.httpPolls, 0);
    });

    test('start is idempotent and stop cancels the tick', () {
      expect(tracker.isPolling, isFalse);

      tracker.start();
      tracker.start();
      expect(tracker.isPolling, isTrue);

      tracker.stop();
      expect(tracker.isPolling, isFalse);
      // A second stop must stay harmless — dispose() calls it too.
      tracker.stop();
      expect(tracker.isPolling, isFalse);
    });

    test('disposing the container cancels a live tick', () {
      tracker.start();
      expect(tracker.isPolling, isTrue);

      // Riverpod disposes the notifier, which cancels the tick and refuses any
      // later use — the screen relies on both halves.
      container.dispose();
      containerDisposed = true;

      expect(tracker.isPolling, isFalse);
    });
  });
}