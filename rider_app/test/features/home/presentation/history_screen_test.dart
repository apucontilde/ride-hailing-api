import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/presentation/history_screen.dart';

Map<String, dynamic> ride(String id) {
  return {
    'id': id,
    'status': 'completed',
    'pickup_address': 'Pickup $id',
    'dropoff_address': 'Dropoff $id',
    'vehicle_type': 'sedan',
    'total_fare': 12.5,
    'requested_at': '2026-01-02T12:00:00Z',
    'completed_at': '2026-01-02T12:30:00Z',
  };
}

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
        child: const MaterialApp(home: HistoryScreen()),
      ),
    );
    await tester.pump();
    await flush(tester);
  }

  testWidgets('renders page 1 of the real history', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.ridesHistory,
      (server) => server.reply(200, {
        'rides': [ride('r1'), ride('r2')],
        'total': 2,
        'page': 1,
        'per_page': 20,
        'total_pages': 1,
      }),
    );

    await pumpScreen(tester);

    expect(find.text('Pickup r1 \u2192 Dropoff r1'), findsOneWidget);
    expect(find.text('Pickup r2 \u2192 Dropoff r2'), findsOneWidget);
    expect(find.text('\$12.50'), findsNWidgets(2));
    expect(find.text('sedan'), findsNWidgets(2));
    expect(find.textContaining('2026-01-02'), findsNWidgets(2));
  });

  testWidgets('scrolling to the bottom loads page 2', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.ridesHistory,
      (server) => server.replyCallback(200, (options) {
        final page = int.parse(options.queryParameters['page'].toString());
        if (page == 1) {
          return {
            'rides': List.generate(20, (i) => ride('p1-$i')),
            'total': 21,
            'page': 1,
            'per_page': 20,
            'total_pages': 2,
          };
        }
        return {
          'rides': [ride('p2-0')],
          'total': 21,
          'page': 2,
          'per_page': 20,
          'total_pages': 2,
        };
      }),
    );

    await pumpScreen(tester);

    expect(find.text('Pickup p1-0 \u2192 Dropoff p1-0'), findsOneWidget);
    expect(find.text('Pickup p2-0 \u2192 Dropoff p2-0'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await flush(tester);
    // Page 2 appends below the old viewport, so scroll once more to build it.
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await flush(tester);

    expect(find.text('Pickup p2-0 \u2192 Dropoff p2-0'), findsOneWidget);
  });

  testWidgets('shows the empty state when the account has no rides',
      (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.ridesHistory,
      (server) => server.reply(200, {
        'rides': <dynamic>[],
        'total': 0,
        'page': 1,
        'per_page': 20,
        'total_pages': 0,
      }),
    );

    await pumpScreen(tester);

    expect(find.text('No rides yet'), findsOneWidget);
  });

  testWidgets('shows the mapped error and a retry action', (tester) async {
    dioAdapter.onGet(
      ApiEndpoints.ridesHistory,
      (server) => server.reply(500, {
        'error': {'code': 'INTERNAL', 'message': 'history query failed'},
      }),
    );

    await pumpScreen(tester);

    expect(find.text('history query failed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('No rides yet'), findsNothing);
  });
}
