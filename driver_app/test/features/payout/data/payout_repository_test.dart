import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';

import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/api_exceptions.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/features/payout/data/payout_repository.dart';

/// Drives the REAL [PayoutRepository] through a Dio mock adapter and pins the
/// URL, the request body and — for the withdrawal — the `Idempotency-Key`
/// header, the one part of the contract the app must supply for replay safety.
void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late List<String> paths;
  late List<Map<String, dynamic>> bodies;
  late List<Map<String, dynamic>> headers;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
    paths = <String>[];
    bodies = <Map<String, dynamic>>[];
    headers = <Map<String, dynamic>>[];
    apiClient.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          paths.add(options.path);
          final data = options.data;
          if (data is Map) {
            bodies.add(Map<String, dynamic>.from(data));
          }
          headers.add(Map<String, dynamic>.from(options.headers));
          handler.next(options);
        },
      ),
    );
  });

  test('fetchEarnings GETs /api/v1/driver/me/earnings and reads the `earnings` key',
      () async {
    dioAdapter.onGet(
      ApiEndpoints.driverEarnings,
      (server) => server.reply(200, {
        'earnings': {
          'available_cents': 2000,
          'pending_cents': 500,
          'withdrawn_cents': 1000,
          'lifetime_cents': 2500,
          'currency': 'USD',
          'month_total_cents': 2550,
          'month_trips': 2,
          'completed_trips': 5,
          'months': [
            {'month': '2026-09', 'total_cents': 1000, 'trips': 1},
            {'month': '2026-08', 'total_cents': 700, 'trips': 1},
          ],
        },
      }),
    );
    final repo = PayoutRepository(apiClient: apiClient);

    final summary = await repo.fetchEarnings();

    expect(ApiEndpoints.driverEarnings, '/api/v1/driver/me/earnings');
    expect(paths.single, ApiEndpoints.driverEarnings);
    expect(summary.availableCents, 2000);
    expect(summary.pendingCents, 500);
    expect(summary.withdrawnCents, 1000);
    expect(summary.lifetimeCents, 2500);
    expect(summary.currency, 'USD');
    expect(summary.monthTotalCents, 2550);
    expect(summary.monthTrips, 2);
    expect(summary.completedTrips, 5);
    // Newest first.
    expect(summary.months.map((m) => m.label).toList(),
        ['September 2026', 'August 2026']);
  });

  test('fetchEarnings treats an absent ledger as a zeroed summary', () async {
    dioAdapter.onGet(
      ApiEndpoints.driverEarnings,
      (server) => server.reply(200, const {}),
    );
    final repo = PayoutRepository(apiClient: apiClient);

    final summary = await repo.fetchEarnings();

    expect(summary.availableCents, 0);
    expect(summary.lifetimeCents, 0);
    expect(summary.currency, isNull);
    expect(summary.months, isEmpty);
  });

  test('requestWithdrawal POSTs {amount_cents} with an Idempotency-Key', () async {
    const key = 'attempt-123';
    dioAdapter.onPost(
      ApiEndpoints.driverEarningsWithdraw,
      (server) => server.reply(200, {
        'withdrawal': {'status': 'pending', 'amount_cents': -1500},
        'earnings': {
          'available_cents': 500,
          'pending_cents': 2000,
          'withdrawn_cents': 1000,
          'lifetime_cents': 2500,
          'currency': 'USD',
          'month_total_cents': 0,
          'month_trips': 0,
          'completed_trips': 5,
          'months': [],
        },
      }),
    );
    final repo = PayoutRepository(apiClient: apiClient);

    final result = await repo.requestWithdrawal(
      amountCents: 1500,
      idempotencyKey: key,
    );

    expect(ApiEndpoints.driverEarningsWithdraw, '/api/v1/driver/earnings/withdraw');
    expect(paths.single, ApiEndpoints.driverEarningsWithdraw);
    expect(bodies.single, {'amount_cents': 1500});
    // The header is the whole replay-safety contract; get its casing/value right.
    expect(
      headers.single.entries
          .where((e) => e.key.toLowerCase() == 'idempotency-key')
          .map((e) => e.value)
          .single,
      key,
    );
    expect(result.withdrawal.isPending, isTrue);
    // A withdrawal is a ledger DEBIT: production returns a negative
    // amount_cents (pinned server-side by tests/payout_test.go:146).
    expect(result.withdrawal.amountCents, -1500);
    expect(result.earnings.availableCents, 500);
  });

  test('a 409 surfaces a typed ConflictException carrying the server message',
      () async {
    dioAdapter.onPost(
      ApiEndpoints.driverEarningsWithdraw,
      (server) => server.reply(409, {
        'error': {'code': 'CONFLICT', 'message': 'insufficient balance'},
      }),
    );
    final repo = PayoutRepository(apiClient: apiClient);

    await expectLater(
      repo.requestWithdrawal(amountCents: 999999, idempotencyKey: 'k'),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<ConflictException>().having(
            (e) => e.message,
            'message',
            'insufficient balance',
          ),
        ),
      ),
    );
  });

  test('a 422 surfaces a typed ValidationException carrying the server message',
      () async {
    dioAdapter.onPost(
      ApiEndpoints.driverEarningsWithdraw,
      (server) => server.reply(422, {
        'error': {'code': 'VALIDATION_ERROR', 'message': 'amount too small'},
      }),
    );
    final repo = PayoutRepository(apiClient: apiClient);

    await expectLater(
      repo.requestWithdrawal(amountCents: 1, idempotencyKey: 'k'),
      throwsA(
        isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<ValidationException>().having(
            (e) => e.message,
            'message',
            'amount too small',
          ),
        ),
      ),
    );
  });
}
