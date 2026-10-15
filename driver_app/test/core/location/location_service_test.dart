import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/location/location_service.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/features/home/providers/availability_notifier.dart';

Position positionFor(double lat, double lng) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime.now(),
    accuracy: 10,
    altitude: 0,
    heading: 0,
    speed: 0,
    speedAccuracy: 0,
    altitudeAccuracy: 0,
    headingAccuracy: 0,
  );
}

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class _FakePermissionLocationService extends LocationService {
  _FakePermissionLocationService({
    required super.apiClient,
    required super.availabilityNotifier,
    required this.permissionResults,
    required this.mockResult,
  }) : super(
          positionStreamProvider: () => const Stream<Position>.empty(),
        );

  final List<({bool granted, bool deniedPermanently})> permissionResults;
  final ({bool granted, bool deniedPermanently}) mockResult;

  @override
  Future<bool> requestPermission() async {
    onPermission?.call(
      granted: mockResult.granted,
      deniedPermanently: mockResult.deniedPermanently,
    );
    permissionResults.add(mockResult);
    return mockResult.granted;
  }
}

/// A geolocator seam so a test can drive the *real* `locationServiceProvider`
/// (whose `LocationService` uses `LocationHelper.getPositionStream`): the
/// provider does not expose a position-stream override, so the platform
/// singleton is the only injection point. Only the stream is faked; every
/// other platform method keeps the base implementation.
class _FakeGeolocatorPlatform extends GeolocatorPlatform {
  _FakeGeolocatorPlatform(this._stream);

  final Stream<Position> _stream;

  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      _stream;
}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late ProviderContainer container;
  late AvailabilityNotifier availability;
  late StreamController<Position> positions;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    container = ProviderContainer(
      overrides: [
        availabilityProvider.overrideWith(
          (ref) => AvailabilityNotifier(ref),
        ),
      ],
    );
    addTearDown(container.dispose);
    availability = container.read(availabilityProvider.notifier);
    positions = StreamController<Position>.broadcast();
    addTearDown(positions.close);
  });

  LocationService buildService({
    Duration throttle = const Duration(milliseconds: 50),
    DateTime Function()? now,
  }) {
    return LocationService(
      apiClient: mockApiClient,
      availabilityNotifier: availability,
      positionStreamProvider: () => positions.stream,
      throttle: throttle,
      now: now,
    );
  }

  LocationService buildServiceWithObserver(
    List<GeoPoint> seen, {
    Duration throttle = const Duration(milliseconds: 50),
    DateTime Function()? now,
  }) {
    return LocationService(
      apiClient: mockApiClient,
      availabilityNotifier: availability,
      positionStreamProvider: () => positions.stream,
      throttle: throttle,
      onPosition: (position) => seen.add(GeoPoint(position.latitude, position.longitude)),
      now: now,
    );
  }

  Response okResponse(String path) => Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {'status': 'ok'},
      );

  group('LocationService', () {
    test('throttles pushes to the configured interval', () async {
      // The throttle reads the injected clock, so the window is advanced
      // explicitly instead of sleeping in real time.
      var now = DateTime(2024, 1, 1);
      final service = buildService(now: () => now);
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));

      availability.setOnline();
      service.start();

      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      // Second position within the throttle window must be skipped.
      now = now.add(const Duration(milliseconds: 20));
      positions.add(positionFor(9.94, -84.09));
      await pumpEventQueue();

      verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).called(1);
      service.stop();
    });

    test('skips pushes while offline', () async {
      final service = buildService();
      availability.setOffline();
      service.start();

      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      positions.add(positionFor(9.94, -84.09));
      await pumpEventQueue();

      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
      service.stop();
    });

    test('publishLastPosition pushes the fix that arrived while offline',
        () async {
      // Regression, and the second half of "the driver never gets an offer":
      // fixes are dropped while offline, and geolocator does not re-emit while
      // the driver is stationary. Going online therefore has to publish the
      // last known position, or the driver holds no `driver_positions` row and
      // dispatch cannot find them for as long as they stand still.
      final service = buildService();
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));

      availability.setOffline();
      service.start();
      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();

      // Nothing pushed while offline...
      verifyNever(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          ));

      // ...but the moment the driver goes online the position goes up, even
      // though the geolocator stream has gone quiet.
      availability.setOnline();
      service.publishLastPosition();
      await pumpEventQueue();

      verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).called(1);
      service.stop();
    });

    test('publishLastPosition bypasses the throttle', () async {
      var now = DateTime(2024, 1, 1);
      final service = buildService(
        throttle: const Duration(seconds: 30),
        now: () => now,
      );
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));

      availability.setOnline();
      service.start();

      // First fix: nothing pushed yet, so it goes straight out.
      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).called(1);
      // `verify` consumes the recorded call, so reset between phases.
      clearInteractions(mockDio);

      // Second fix lands inside the 30 s window and is throttled away.
      positions.add(positionFor(9.94, -84.09));
      await pumpEventQueue();
      verifyNever(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          ));
      clearInteractions(mockDio);

      // An explicit publish must not be throttled away, and must carry the
      // *newest* fix: a driver coming online is not a routine ping, it is the
      // row dispatch is about to search on.
      service.publishLastPosition();
      await pumpEventQueue();

      final calls = verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: captureAny(named: 'data'),
          )).captured;
      expect(calls.length, 1);
      expect((calls.single as Map)['lat'], 9.94);
      service.stop();
    });

    test('publishLastPosition is a no-op with no fix and while offline',
        () async {
      final service = buildService();
      when(() => mockDio.put(any(), data: any(named: 'data')))
          .thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));
      availability.setOnline();

      // No fix has arrived yet — nothing to publish, and nothing invented.
      service.publishLastPosition();
      await pumpEventQueue();
      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));

      // A fix arrives, but the driver is still offline.
      availability.setOffline();
      service.start();
      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();

      // Explicitly asking while offline must not push either; the online gate
      // is the server contract, not a UI hint.
      service.publishLastPosition();
      await pumpEventQueue();
      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
      service.stop();
    });

    test('publishes every fix even when the server push is gated or throttled',
        () async {
      // The trip map and the >200 m route refetch read the driver's real
      // position, which must not depend on the online/throttle gates.
      var now = DateTime(2024, 1, 1);
      final seen = <GeoPoint>[];
      final service = buildServiceWithObserver(
        seen,
        throttle: const Duration(seconds: 30),
        now: () => now,
      );
      availability.setOnline();
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));
      service.start();

      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      // Throttled out of the server push, but the app still sees it.
      positions.add(positionFor(9.94, -84.09));
      await pumpEventQueue();

      expect(seen, const [GeoPoint(9.93, -84.08), GeoPoint(9.94, -84.09)]);
      verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).called(1);
      service.stop();
    });

    test('publishes fixes while offline', () async {
      final seen = <GeoPoint>[];
      final service = buildServiceWithObserver(seen);
      availability.setOffline();
      service.start();

      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();

      expect(seen, const [GeoPoint(9.93, -84.08)]);
      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
      service.stop();
    });

    test('GeoPoint compares by value', () {
      expect(const GeoPoint(9.93, -84.08), const GeoPoint(9.93, -84.08));
      expect(const GeoPoint(9.93, -84.08).hashCode,
          const GeoPoint(9.93, -84.08).hashCode);
      expect(const GeoPoint(9.93, -84.08), isNot(const GeoPoint(9.94, -84.08)));
    });

    test('buffers a failed push and flushes it as a batch on next success',
        () async {
      var now = DateTime(2024, 1, 1);
      final service = buildService(now: () => now);
      availability.setOnline();

      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.driverLocation),
      ));

      service.start();
      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();

      // Next push succeeds: the buffered point is flushed via the batch
      // endpoint. Advance the clock past the throttle window first.
      now = now.add(const Duration(milliseconds: 100));
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));
      when(() => mockDio.put(
            ApiEndpoints.driverLocationBatch,
            data: any(named: 'data'),
          )).thenAnswer(
        (_) async => okResponse(ApiEndpoints.driverLocationBatch),
      );

      positions.add(positionFor(9.94, -84.09));
      await pumpEventQueue();

      // The second, successful single push carried the latest point; the
      // earlier failed one was buffered, not re-sent.
      verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: {
              'lat': 9.94,
              'lng': -84.09,
              'heading': 0.0,
              'speed': 0.0,
            },
          )).called(1);
      verify(() => mockDio.put(
            ApiEndpoints.driverLocationBatch,
            data: {
              'points': [
                {
                  'lat': 9.93,
                  'lng': -84.08,
                  'heading': 0.0,
                  'speed': 0.0,
                },
              ],
            },
          )).called(1);
      // The failed push was buffered and the service is still live, so the next
      // fix can be pushed and the buffer flushed.
      expect(service.active, isTrue);
      service.stop();
    });

    test('stops the subscription on dispose', () async {
      final service = buildService();
      service.start();
      expect(service.active, isTrue);
      service.dispose();
      expect(service.active, isFalse);
    });

    test('setForegroundTracking swaps to the foreground stream while active',
        () async {
      // Bug #18: an online driver must be backed by the Android foreground
      // service. The switch must actually re-subscribe, not just flip a flag,
      // or the persistent notification would never attach.
      final plain = StreamController<Position>.broadcast();
      final foreground = StreamController<Position>.broadcast();
      addTearDown(plain.close);
      addTearDown(foreground.close);

      final seen = <GeoPoint>[];
      final service = LocationService(
        apiClient: mockApiClient,
        availabilityNotifier: availability,
        positionStreamProvider: () => plain.stream,
        foregroundPositionStreamProvider: () => foreground.stream,
        onPosition: (p) => seen.add(GeoPoint(p.latitude, p.longitude)),
      );
      addTearDown(service.dispose);

      expect(service.foregroundTracking, isFalse);
      service.start();
      expect(service.active, isTrue);

      service.setForegroundTracking(true);
      expect(service.foregroundTracking, isTrue);

      // The foreground stream now feeds the service...
      foreground.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      expect(seen, const [GeoPoint(9.93, -84.08)]);

      // ...and the old plain subscription is gone.
      plain.add(positionFor(1, 1));
      await pumpEventQueue();
      expect(seen, const [GeoPoint(9.93, -84.08)]);

      // Going offline must detach the service again.
      service.setForegroundTracking(false);
      expect(service.foregroundTracking, isFalse);
      plain.add(positionFor(9.94, -84.09));
      await pumpEventQueue();
      expect(seen.last, const GeoPoint(9.94, -84.09));
    });

    test('start() honours a foreground flag armed before the stream', () async {
      final plain = StreamController<Position>.broadcast();
      final foreground = StreamController<Position>.broadcast();
      addTearDown(plain.close);
      addTearDown(foreground.close);

      final seen = <GeoPoint>[];
      final service = LocationService(
        apiClient: mockApiClient,
        availabilityNotifier: availability,
        positionStreamProvider: () => plain.stream,
        foregroundPositionStreamProvider: () => foreground.stream,
        onPosition: (p) => seen.add(GeoPoint(p.latitude, p.longitude)),
      );
      addTearDown(service.dispose);

      // Arm before any subscription exists (the provider's onOnlineChanged hook
      // can fire before the first start()).
      service.setForegroundTracking(true);
      service.start();

      foreground.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      expect(seen, const [GeoPoint(9.93, -84.08)]);

      plain.add(positionFor(1, 1));
      await pumpEventQueue();
      expect(seen, const [GeoPoint(9.93, -84.08)]);
    });

    test('stop() clears foreground tracking so a logout cannot keep the service',
        () async {
      final plain = StreamController<Position>.broadcast();
      final foreground = StreamController<Position>.broadcast();
      addTearDown(plain.close);
      addTearDown(foreground.close);

      final service = LocationService(
        apiClient: mockApiClient,
        availabilityNotifier: availability,
        positionStreamProvider: () => plain.stream,
        foregroundPositionStreamProvider: () => foreground.stream,
      );
      addTearDown(service.dispose);

      service.start();
      service.setForegroundTracking(true);
      expect(service.foregroundTracking, isTrue);

      service.stop();
      expect(service.foregroundTracking, isFalse);
      expect(service.active, isFalse);

      // A restart after the teardown uses the plain stream until re-armed.
      service.start();
      foreground.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      // No onPosition observer here, but the service must still be subscribed to
      // the plain stream; it simply must not be in foreground mode.
      expect(service.foregroundTracking, isFalse);
    });

    test('setForegroundTracking is idempotent', () async {
      final plain = StreamController<Position>.broadcast();
      final foreground = StreamController<Position>.broadcast();
      addTearDown(plain.close);
      addTearDown(foreground.close);

      final seen = <GeoPoint>[];
      final service = LocationService(
        apiClient: mockApiClient,
        availabilityNotifier: availability,
        positionStreamProvider: () => plain.stream,
        foregroundPositionStreamProvider: () => foreground.stream,
        onPosition: (p) => seen.add(GeoPoint(p.latitude, p.longitude)),
      );
      addTearDown(service.dispose);

      service.start();
      service.setForegroundTracking(true);
      service.setForegroundTracking(true);

      foreground.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      // A duplicate arm must not re-subscribe and duplicate events.
      expect(seen, const [GeoPoint(9.93, -84.08)]);
    });

    test('requestPermission calls onPermission with granted when OS grants',
        () async {
      final permissionResults = <({bool granted, bool deniedPermanently})>[];
      // A subclass that fakes the helper/geolocator seam.
      final fakeService = _FakePermissionLocationService(
        apiClient: mockApiClient,
        availabilityNotifier: availability,
        permissionResults: permissionResults,
        mockResult: (granted: true, deniedPermanently: false),
      );
      final granted = await fakeService.requestPermission();
      expect(granted, isTrue);
      expect(permissionResults.length, 1);
      expect(permissionResults.single.granted, isTrue);
      expect(permissionResults.single.deniedPermanently, isFalse);
    });

    test('the provider binding re-publishes the last fix on reconnect',
        () async {
      // Regression for location_service.dart: the provider owns the
      // reconnect hook (`websocket.onReconnected = () => service
      // .publishLastPosition()`), and no test instantiated it. Build the real
      // provider wiring with the websocket + geolocator seam faked, feed one
      // fix, then fire the hook the way a real reconnect does.
      final positions = StreamController<Position>.broadcast();
      addTearDown(positions.close);
      GeolocatorPlatform.instance = _FakeGeolocatorPlatform(positions.stream);

      final websocket = DriverWebSocketService(WebSocketService());
      addTearDown(websocket.dispose);

      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(mockApiClient),
          driverWebSocketServiceProvider.overrideWithValue(websocket),
          availabilityProvider.overrideWith(
            (ref) => AvailabilityNotifier(ref),
          ),
        ],
      );
      addTearDown(container.dispose);

      var pushed = false;
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async {
        pushed = true;
        return okResponse(ApiEndpoints.driverLocation);
      });

      final service = container.read(locationServiceProvider);
      final availability = container.read(availabilityProvider.notifier);

      // Stay offline while seeding the fix so the seed itself pushes nothing;
      // the reconnect is then the only thing that can trigger a PUT.
      availability.setOffline();
      service.start();
      positions.add(positionFor(9.93, -84.08));
      await pumpEventQueue();
      expect(container.read(lastPositionProvider), isNotNull);
      clearInteractions(mockDio);

      availability.setOnline();
      expect(websocket.onReconnected, isNotNull,
          reason: 'locationServiceProvider must bind the reconnect hook');

      websocket.onReconnected!();
      await pumpEventQueue();

      expect(pushed, isTrue);
      verify(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: {
              'lat': 9.93,
              'lng': -84.08,
              'heading': 0.0,
              'speed': 0.0,
            },
          )).called(1);
      service.stop();
    });
  });
}
