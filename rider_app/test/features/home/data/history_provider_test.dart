import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/history_provider.dart';
import 'package:rider_app/features/home/model/ride_summary.dart';

Map<String, dynamic> ride(
  String id, {
  String status = 'completed',
  double fare = 12.5,
}) {
  return {
    'id': id,
    'status': status,
    'pickup_address': 'Main St $id',
    'dropoff_address': 'Airport Rd $id',
    'vehicle_type': 'sedan',
    'total_fare': fare,
    'requested_at': '2026-01-02T12:00:00Z',
    'completed_at': '2026-01-02T12:30:00Z',
  };
}

Map<String, dynamic> page(
  List<Map<String, dynamic>> rides, {
  required int page,
  required int totalPages,
  required int total,
}) {
  return {
    'rides': rides,
    'total': total,
    'page': page,
    'per_page': 20,
    'total_pages': totalPages,
  };
}

void main() {
  group('HistoryNotifier', () {
    late ApiClient apiClient;
    late DioAdapter dioAdapter;
    late ProviderContainer container;
    late HistoryNotifier notifier;
    late List<Map<String, dynamic>> requests;

    setUp(() {
      apiClient = ApiClient(baseUrl: 'http://localhost:8080');
      dioAdapter = DioAdapter(
        dio: apiClient.dio,
        matcher: const UrlRequestMatcher(matchMethod: true),
      );
      requests = <Map<String, dynamic>>[];
      apiClient.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(Map<String, dynamic>.from(options.queryParameters));
            handler.next(options);
          },
        ),
      );
      container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(apiClient)],
      );
      notifier = container.read(historyProvider.notifier);
      addTearDown(container.dispose);
    });

    test('firstPage renders page 1 and asks for per_page=20', () async {
      dioAdapter.onGet(
        ApiEndpoints.ridesHistory,
        (server) => server.reply(
          200,
          page([ride('r1'), ride('r2')], page: 1, totalPages: 1, total: 2),
        ),
      );

      await notifier.firstPage();

      expect(notifier.state.rides, hasLength(2));
      expect(notifier.state.rides.first.id, 'r1');
      expect(notifier.state.page, 1);
      expect(notifier.state.totalPages, 1);
      expect(notifier.state.hasMore, isFalse);
      expect(notifier.state.error, isNull);
      expect(requests.single['page'], 1);
      expect(requests.single['per_page'], 20);
    });

    test('loadMore appends the next page and flips hasMore at total_pages',
        () async {
      dioAdapter.onGet(
        ApiEndpoints.ridesHistory,
        (server) => server.replyCallback(200, (options) {
          final requested = int.parse(options.queryParameters['page'].toString());
          return requested == 1
              ? page([ride('r1')], page: 1, totalPages: 2, total: 2)
              : page([ride('r2')], page: 2, totalPages: 2, total: 2);
        }),
      );

      await notifier.firstPage();
      expect(notifier.state.hasMore, isTrue);

      await notifier.loadMore();

      expect(notifier.state.rides.map((r) => r.id), ['r1', 'r2']);
      expect(notifier.state.page, 2);
      expect(notifier.state.hasMore, isFalse);
      expect(requests.last['page'], 2);

      // No out-of-range request once the last page is reached.
      await notifier.loadMore();
      expect(requests, hasLength(2));
    });

    test('empty list is an empty state, not an error', () async {
      dioAdapter.onGet(
        ApiEndpoints.ridesHistory,
        (server) => server.reply(
          200,
          page(const [], page: 1, totalPages: 0, total: 0),
        ),
      );

      await notifier.firstPage();

      expect(notifier.state.rides, isEmpty);
      expect(notifier.state.hasMore, isFalse);
      expect(notifier.state.error, isNull);
    });

    test('server error maps to the backend message', () async {
      dioAdapter.onGet(
        ApiEndpoints.ridesHistory,
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'history query failed'},
        }),
      );

      await notifier.firstPage();

      expect(notifier.state.error, 'history query failed');
      expect(notifier.state.rides, isEmpty);
      expect(notifier.state.hasMore, isFalse);
    });
  });

  group('RideSummary.fromJson', () {
    test('parses the history fields', () {
      final summary = RideSummary.fromJson(ride('r9', fare: 9.75));
      expect(summary.id, 'r9');
      expect(summary.status, 'completed');
      expect(summary.pickupAddress, 'Main St r9');
      expect(summary.dropoffAddress, 'Airport Rd r9');
      expect(summary.vehicleType, 'sedan');
      expect(summary.totalFare, 9.75);
      expect(summary.requestedAt, '2026-01-02T12:00:00Z');
      expect(summary.completedAt, '2026-01-02T12:30:00Z');
    });

    test('defaults missing fields instead of throwing', () {
      final summary = RideSummary.fromJson(const {});
      expect(summary.id, '');
      expect(summary.status, '');
      expect(summary.totalFare, 0);
      expect(summary.requestedAt, isNull);
    });
  });
}
