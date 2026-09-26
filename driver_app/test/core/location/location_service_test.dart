import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/location/location_service.dart';
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

  LocationService buildService({Duration throttle = const Duration(milliseconds: 50)}) {
    return LocationService(
      apiClient: mockApiClient,
      availabilityNotifier: availability,
      positionStreamProvider: () => positions.stream,
      throttle: throttle,
    );
  }

  LocationService buildServiceWithObserver(
    List<GeoPoint> seen, {
    Duration throttle = const Duration(milliseconds: 50),
  }) {
    return LocationService(
      apiClient: mockApiClient,
      availabilityNotifier: availability,
      positionStreamProvider: () => positions.stream,
      throttle: throttle,
      onPosition: (position) => seen.add(GeoPoint(position.latitude, position.longitude)),
    );
  }

  Response okResponse(String path) => Response(
        requestOptions: RequestOptions(path: path),
        statusCode: 200,
        data: {'status': 'ok'},
      );

  group('LocationService', () {
    test('throttles pushes to the configured interval', () async {
      final service = buildService();
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));

      availability.setOnline();
      service.start();

      positions.add(positionFor(9.93, -84.08));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Second position within the throttle window must be skipped.
      positions.add(positionFor(9.94, -84.09));
      await Future<void>.delayed(const Duration(milliseconds: 120));

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
      await Future<void>.delayed(const Duration(milliseconds: 100));
      positions.add(positionFor(9.94, -84.09));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
      service.stop();
    });

    test('publishes every fix even when the server push is gated or throttled',
        () async {
      // The trip map and the >200 m route refetch read the driver's real
      // position, which must not depend on the online/throttle gates.
      final seen = <GeoPoint>[];
      final service = buildServiceWithObserver(
        seen,
        throttle: const Duration(seconds: 30),
      );
      availability.setOnline();
      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenAnswer((_) async => okResponse(ApiEndpoints.driverLocation));
      service.start();

      positions.add(positionFor(9.93, -84.08));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Throttled out of the server push, but the app still sees it.
      positions.add(positionFor(9.94, -84.09));
      await Future<void>.delayed(const Duration(milliseconds: 20));

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
      await Future<void>.delayed(const Duration(milliseconds: 20));

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
      final service = buildService();
      availability.setOnline();

      when(() => mockDio.put(
            ApiEndpoints.driverLocation,
            data: any(named: 'data'),
          )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.driverLocation),
      ));

      service.start();
      positions.add(positionFor(9.93, -84.08));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Next push succeeds: the buffered point is flushed via the batch
      // endpoint.
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
      await Future<void>.delayed(const Duration(milliseconds: 100));

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
      expect(service, isNotNull);
      service.stop();
    });

    test('stops the subscription on dispose', () async {
      final service = buildService();
      service.start();
      expect(service.active, isTrue);
      service.dispose();
      expect(service.active, isFalse);
    });
  });
}