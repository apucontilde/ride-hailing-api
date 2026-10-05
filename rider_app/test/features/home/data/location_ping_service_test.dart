import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/features/home/data/location_ping_service.dart';

Position position(double lat, double lng) {
  return Position(
    latitude: lat,
    longitude: lng,
    timestamp: DateTime(2026, 1, 1),
    accuracy: 1,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late StreamController<Position> controller;
  late DateTime currentTime;
  late List<Map<String, dynamic>> bodies;
  var listenCount = 0;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
    bodies = <Map<String, dynamic>>[];
    apiClient.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final data = options.data;
          if (data is Map) {
            bodies.add(Map<String, dynamic>.from(data));
          }
          handler.next(options);
        },
      ),
    );
    controller = StreamController<Position>.broadcast();
    listenCount = 0;
    controller.onListen = () => listenCount++;
    currentTime = DateTime(2026, 1, 1, 12, 0, 0);
  });

  tearDown(() async {
    await controller.close();
  });

  LocationPingService build() => LocationPingService(
        apiClient,
        positionStream: () => controller.stream,
        now: () => currentTime,
      );

  test('sends one ping per throttle window and forwards coordinates',
      () async {
    dioAdapter.onPut(
      ApiEndpoints.riderLocation,
      (server) => server.reply(204, null),
    );
    final service = build();
    service.start();

    controller.add(position(9.5, -84.5));
    await pumpEventQueue();

    controller.add(position(9.6, -84.6));
    await pumpEventQueue();

    expect(bodies, hasLength(1));
    expect(bodies.single['lat'], 9.5);
    expect(bodies.single['lng'], -84.5);

    currentTime = currentTime.add(const Duration(seconds: 5));
    controller.add(position(9.7, -84.7));
    await pumpEventQueue();

    expect(bodies, hasLength(2));
    expect(bodies.last['lat'], 9.7);

    await service.stop();
  });

  test('a 204 response is handled without parsing a body', () async {
    dioAdapter.onPut(
      ApiEndpoints.riderLocation,
      (server) => server.reply(204, null),
    );
    final service = build();
    service.start();

    controller.add(position(9.5, -84.5));
    await pumpEventQueue();

    expect(bodies, hasLength(1));
    await service.stop();
  });

  test('swallows a 4xx without surfacing an error', () async {
    dioAdapter.onPut(
      ApiEndpoints.riderLocation,
      (server) => server.reply(422, {'message': 'invalid location'}),
    );
    final service = build();
    service.start();

    controller.add(position(9.5, -84.5));
    await pumpEventQueue();

    expect(bodies, hasLength(1));
    expect(service.isActive, isTrue);
    await service.stop();
  });

  test('stop cancels the stream so no further ping is sent', () async {
    dioAdapter.onPut(
      ApiEndpoints.riderLocation,
      (server) => server.reply(204, null),
    );
    final service = build();
    service.start();

    controller.add(position(9.5, -84.5));
    await pumpEventQueue();
    expect(bodies, hasLength(1));

    await service.stop();
    currentTime = currentTime.add(const Duration(seconds: 10));
    controller.add(position(9.9, -84.9));
    await pumpEventQueue();

    expect(bodies, hasLength(1));
    expect(service.isActive, isFalse);
  });

  test('a second start does not open a second subscription', () async {
    dioAdapter.onPut(
      ApiEndpoints.riderLocation,
      (server) => server.reply(204, null),
    );
    final service = build();

    service.start();
    service.start();

    expect(service.isActive, isTrue);
    expect(listenCount, 1);

    await service.stop();
    await service.stop();
    expect(service.isActive, isFalse);
  });

  test(
    'an outgoing screen stop does not cancel the lease an incoming screen holds',
    () async {
      dioAdapter.onPut(
        ApiEndpoints.riderLocation,
        (server) => server.reply(204, null),
      );
      final service = build();

      // Home mounts…
      service.start();
      // …the flow screen mounts before home's dispose runs, so both hold a
      // lease for a frame. go_router mounts the incoming route first.
      service.start();
      // Home disposes and releases only its own lease.
      await service.stop();

      expect(
        service.isActive,
        isTrue,
        reason: 'the live trip still holds a lease',
      );
      expect(listenCount, 1);

      // The stream is still live and the fix is streamed.
      controller.add(position(9.5, -84.5));
      await pumpEventQueue();
      expect(bodies, hasLength(1));

      // The trip ends: the last lease is released and the stream is torn down.
      await service.stop();
      expect(service.isActive, isFalse);

      currentTime = currentTime.add(const Duration(seconds: 10));
      controller.add(position(9.9, -84.9));
      await pumpEventQueue();
      expect(bodies, hasLength(1), reason: 'cancelled after the last stop');
    },
  );
}
