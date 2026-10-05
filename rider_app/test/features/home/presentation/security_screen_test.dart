import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/features/home/data/security_provider.dart';
import 'package:rider_app/features/home/presentation/security_screen.dart';

Position position() {
  return Position(
    latitude: 9.5,
    longitude: -84.5,
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

  Future<void> pumpScreen(
    WidgetTester tester, {
    required SecurityNotifier notifier,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [securityProvider.overrideWith((ref) => notifier)],
        child: const MaterialApp(home: SecurityScreen()),
      ),
    );
    await tester.pump();
  }

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('states the ack-only limitation and never claims dispatch',
      (tester) async {
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(),
    );

    await pumpScreen(tester, notifier: notifier);

    expect(
      find.textContaining('acknowledgment only'),
      findsOneWidget,
    );
    expect(find.textContaining('does not yet persist or dispatch'), findsOneWidget);
    expect(find.textContaining('support has been notified'), findsNothing);
  });

  testWidgets('confirming sends the SOS and shows the success banner',
      (tester) async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(201, {'message': 'SOS alert received'}),
    );
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(),
    );

    await pumpScreen(tester, notifier: notifier);

    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pumpAndSettle();
    expect(find.text('Send emergency alert?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sos-confirm')));
    await flush(tester);

    expect(
      find.text('Emergency alert sent \u2014 support has been notified'),
      findsOneWidget,
    );
    expect(bodies, hasLength(1));
  });

  testWidgets('cancelling the dialog sends nothing', (tester) async {
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(),
    );

    await pumpScreen(tester, notifier: notifier);

    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(bodies, isEmpty);
    expect(find.byKey(const Key('sos-success')), findsNothing);
  });

  testWidgets('a failed send shows the mapped failure banner', (tester) async {
    dioAdapter.onPost(
      ApiEndpoints.sos,
      (server) => server.reply(500, {
        'error': {'code': 'INTERNAL', 'message': 'dispatch failed'},
      }),
    );
    final notifier = SecurityNotifier(
      apiClient,
      lastPosition: () async => position(),
    );

    await pumpScreen(tester, notifier: notifier);

    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sos-confirm')));
    await flush(tester);

    expect(find.byKey(const Key('sos-error')), findsOneWidget);
    expect(find.text('dispatch failed'), findsOneWidget);
    expect(find.byKey(const Key('sos-success')), findsNothing);
  });
}
