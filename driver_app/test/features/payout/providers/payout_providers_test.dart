import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:driver_app/core/api/api_exceptions.dart';
import 'package:driver_app/features/payout/data/payout_repository.dart';
import 'package:driver_app/features/payout/model/driver_earnings.dart';
import 'package:driver_app/features/payout/providers/payout_providers.dart';
import 'package:driver_app/features/rides/data/rides_repository.dart';

class MockPayoutRepository extends Mock implements PayoutRepository {}

DriverEarningsSummary summary({int availableCents = 0, String? currency = 'USD'}) {
  return DriverEarningsSummary(
    availableCents: availableCents,
    pendingCents: 0,
    withdrawnCents: 0,
    lifetimeCents: availableCents,
    currency: currency,
    monthTotalCents: 0,
    monthTrips: 0,
    completedTrips: 0,
    months: const [],
  );
}

DioException _failure({int? status, String message = 'boom'}) {
  final mapped = status == null ? null : mapStatusCodeToException(status, message);
  return DioException(
    requestOptions: RequestOptions(path: '/x'),
    type: status == null
        ? DioExceptionType.connectionError
        : DioExceptionType.badResponse,
    error: mapped,
  );
}

void main() {
  late MockPayoutRepository repo;
  late ProviderContainer container;

  setUp(() {
    repo = MockPayoutRepository();
    container = ProviderContainer(
      overrides: [payoutRepositoryProvider.overrideWith((ref) => repo)],
    );
    addTearDown(container.dispose);
  });

  void stubFetch(DriverEarningsSummary value) {
    when(() => repo.fetchEarnings()).thenAnswer((_) async => value);
  }

  void stubWithdraw(
    Future<WithdrawalResult> Function(String key) answer, {
    List<String>? keys,
  }) {
    when(
      () => repo.requestWithdrawal(
        amountCents: any(named: 'amountCents'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((invocation) {
      final key = invocation.namedArguments[#idempotencyKey] as String;
      keys?.add(key);
      return answer(key);
    });
  }

  test('earningsProvider loads the summary from the repository', () async {
    stubFetch(summary(availableCents: 2000));

    final value = await container.read(earningsProvider.future);

    expect(value.availableCents, 2000);
  });

  test('earningsProvider never reads historyProvider (the old source)', () async {
    stubFetch(summary(availableCents: 42));
    // A rides repository that throws if anyone reaches for it: the ledger must
    // be endpoint-backed now, not a sum over the loaded ride pages.
    final isolated = ProviderContainer(
      overrides: [
        payoutRepositoryProvider.overrideWith((ref) => repo),
        ridesRepositoryProvider.overrideWith(
          (ref) => throw StateError('history must not be read'),
        ),
      ],
    );
    addTearDown(isolated.dispose);

    final value = await isolated.read(earningsProvider.future);

    expect(value.availableCents, 42);
  });

  test('refresh keeps the previous summary readable while loading', () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final gate = Completer<DriverEarningsSummary>();
    when(() => repo.fetchEarnings()).thenAnswer((_) => gate.future);
    final refreshing = container.read(earningsProvider.notifier).refresh();

    final during = container.read(earningsProvider);
    expect(during.isLoading, isTrue);
    expect(during.valueOrNull?.availableCents, 2000);

    gate.complete(summary(availableCents: 500));
    await refreshing;
    expect(container.read(earningsProvider).valueOrNull?.availableCents, 500);
  });

  test('a successful submit records the withdrawal and applies the ledger',
      () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final keys = <String>[];
    stubWithdraw(
      (_) async => WithdrawalResult(
        withdrawal: const DriverWithdrawal(status: 'pending', amountCents: -1500),
        earnings: summary(availableCents: 500),
      ),
      keys: keys,
    );

    await container
        .read(withdrawControllerProvider.notifier)
        .submit(amountCents: 1500);

    final state = container.read(withdrawControllerProvider);
    expect(state.isSubmitted, isTrue);
    expect(keys, hasLength(1));
    expect(keys.single, isNotEmpty);
    // The server's updated ledger moves the balance without a second request.
    expect(container.read(earningsProvider).valueOrNull?.availableCents, 500);
  });

  test('a second submit while one is in flight is a no-op', () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final gate = Completer<WithdrawalResult>();
    var calls = 0;
    stubWithdraw((_) {
      calls++;
      return gate.future;
    });

    final controller = container.read(withdrawControllerProvider.notifier);
    final first = controller.submit(amountCents: 1000);
    final second = controller.submit(amountCents: 1000);

    gate.complete(
      WithdrawalResult(
        withdrawal: const DriverWithdrawal(status: 'pending', amountCents: -1000),
        earnings: summary(availableCents: 1000),
      ),
    );
    await first;
    await second;

    expect(calls, 1);
  });

  test('a transport failure keeps the key so a retry replays it', () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final keys = <String>[];
    stubWithdraw((_) async => throw _failure(), keys: keys);

    final controller = container.read(withdrawControllerProvider.notifier);
    await controller.submit(amountCents: 1000);
    expect(
      container.read(withdrawControllerProvider).errorKind,
      WithdrawErrorKind.transport,
    );

    // Retry replays the SAME key: the first request may already have been
    // written, so a new key could double-debit.
    await controller.retry();

    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });

  test('a 5xx is ambiguous, so its key is kept across a retry too', () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final keys = <String>[];
    stubWithdraw((_) async => throw _failure(status: 500), keys: keys);

    final controller = container.read(withdrawControllerProvider.notifier);
    await controller.submit(amountCents: 1000);
    await controller.retry();

    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });

  test('a 409 shows the server message, refreshes the balance and drops the key',
      () async {
    var earningsCalls = 0;
    when(() => repo.fetchEarnings()).thenAnswer((_) async {
      earningsCalls++;
      return summary(availableCents: earningsCalls == 1 ? 2000 : 100);
    });
    await container.read(earningsProvider.future);

    final keys = <String>[];
    stubWithdraw(
      (_) async => throw _failure(status: 409, message: 'insufficient balance'),
      keys: keys,
    );

    final controller = container.read(withdrawControllerProvider.notifier);
    await controller.submit(amountCents: 5000);

    final state = container.read(withdrawControllerProvider);
    expect(state.errorKind, WithdrawErrorKind.conflict);
    expect(state.message, 'insufficient balance');
    expect(earningsCalls, 2);
    expect(container.read(earningsProvider).valueOrNull?.availableCents, 100);

    // A terminal 4xx was rejected before any write, so the next attempt is a
    // brand-new key even for the same amount.
    await controller.submit(amountCents: 5000);
    expect(keys, hasLength(2));
    expect(keys[0], isNot(keys[1]));
  });

  test('a 422 marks the amount invalid with the server message', () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    stubWithdraw(
      (_) async => throw _failure(status: 422, message: 'amount too small'),
    );

    await container
        .read(withdrawControllerProvider.notifier)
        .submit(amountCents: 10);

    final state = container.read(withdrawControllerProvider);
    expect(state.errorKind, WithdrawErrorKind.validation);
    expect(state.message, 'amount too small');
    // The balance did not move, so no refresh was needed.
    expect(container.read(earningsProvider).valueOrNull?.availableCents, 2000);
  });

  test('generateWithdrawKey is non-empty and varies between calls', () {
    final a = generateWithdrawKey();
    final b = generateWithdrawKey();

    expect(a, isNotEmpty);
    expect(a, isNot(b));
  });

  test('present() clears the view but keeps the key for a same-amount replay',
      () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final keys = <String>[];
    stubWithdraw((_) async => throw _failure(), keys: keys);
    final controller = container.read(withdrawControllerProvider.notifier);

    await controller.submit(amountCents: 1000);
    // The sheet was closed and reopened: the stale error must not show, but the
    // ambiguous attempt's key must survive.
    controller.present();
    expect(container.read(withdrawControllerProvider).phase, WithdrawPhase.idle);

    await controller.submit(amountCents: 1000);
    expect(keys, hasLength(2));
    expect(keys[0], keys[1]);
  });

  test('present() after a success opens a fresh form with a new key', () async {
    stubFetch(summary(availableCents: 2000));
    await container.read(earningsProvider.future);

    final keys = <String>[];
    stubWithdraw(
      (_) async => WithdrawalResult(
        withdrawal: const DriverWithdrawal(status: 'pending', amountCents: -1000),
        earnings: summary(availableCents: 1000),
      ),
      keys: keys,
    );
    final controller = container.read(withdrawControllerProvider.notifier);

    await controller.submit(amountCents: 1000);
    expect(container.read(withdrawControllerProvider).isSubmitted, isTrue);

    controller.present();
    expect(container.read(withdrawControllerProvider).phase, WithdrawPhase.idle);

    // The success cleared the key, so the next withdrawal is a brand-new one.
    await controller.submit(amountCents: 1000);
    expect(keys, hasLength(2));
    expect(keys[0], isNot(keys[1]));
  });
}
