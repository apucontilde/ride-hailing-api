import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/features/home/data/security_provider.dart';

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
  late List<Map<String, dynamic>> bodies;

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
  });

  test('201 acknowledgement reports success with the fix coordinates', () async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(201, {
        'message': 'SOS alert received',
        'alert': {'status': 'active'},
      }),
    );
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(9.5, -84.5),
    );
    addTearDown(notifier.dispose);

    await notifier.sendSos();

    expect(notifier.state.success, isTrue);
    expect(notifier.state.error, isNull);
    expect(notifier.state.isSending, isFalse);
    expect(bodies.single['lat'], 9.5);
    expect(bodies.single['lng'], -84.5);
  });

  test('non-2xx reports the backend error', () async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(500, {
        'error': {'code': 'INTERNAL', 'message': 'dispatch failed'},
      }),
    );
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(9.5, -84.5),
    );
    addTearDown(notifier.dispose);

    await notifier.sendSos();

    expect(notifier.state.success, isFalse);
    expect(notifier.state.error, 'dispatch failed');
  });

  test('falls back to the ride pickup when there is no last fix', () async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(201, {'message': 'SOS alert received'}),
    );
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => null,
      fallbackPosition: () => (9.93, -84.08),
    );
    addTearDown(notifier.dispose);

    await notifier.sendSos();

    expect(notifier.state.success, isTrue);
    expect(bodies.single['lat'], 9.93);
    expect(bodies.single['lng'], -84.08);
  });

  test('no position anywhere fails without firing a request', () async {
    final notifier = SecurityNotifier(apiClient, lastPosition: () async => null);
    addTearDown(notifier.dispose);

    await notifier.sendSos();

    expect(notifier.state.success, isFalse);
    expect(notifier.state.error, isNotNull);
    expect(bodies, isEmpty);
  });

  test('concurrent double-fire only sends one request', () async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(201, {'message': 'SOS alert received'}),
    );
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(9.5, -84.5),
    );
    addTearDown(notifier.dispose);

    final first = notifier.sendSos();
    final second = notifier.sendSos();
    await Future.wait([first, second]);

    expect(bodies, hasLength(1));
    expect(notifier.state.success, isTrue);
  });
}
