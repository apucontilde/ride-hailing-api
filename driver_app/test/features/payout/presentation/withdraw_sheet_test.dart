import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:driver_app/core/api/api_exceptions.dart';
import 'package:driver_app/features/payout/data/payout_repository.dart';
import 'package:driver_app/features/payout/model/driver_earnings.dart';
import 'package:driver_app/features/payout/presentation/withdraw_sheet.dart';

class MockPayoutRepository extends Mock implements PayoutRepository {}

DriverEarningsSummary ledger({
  int availableCents = 2000,
  String? currency = 'USD',
}) {
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

DioException _failure({required int status, required String message}) {
  return DioException(
    requestOptions: RequestOptions(path: '/x'),
    type: DioExceptionType.badResponse,
    error: mapStatusCodeToException(status, message),
  );
}

DioException _transport() {
  return DioException(
    requestOptions: RequestOptions(path: '/x'),
    type: DioExceptionType.connectionError,
  );
}

void main() {
  late MockPayoutRepository repo;

  setUp(() {
    repo = MockPayoutRepository();
  });

  void stubWithdraw(Future<WithdrawalResult> Function(String key) answer) {
    when(
      () => repo.requestWithdrawal(
        amountCents: any(named: 'amountCents'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((inv) => answer(inv.namedArguments[#idempotencyKey] as String));
  }

  /// Pumps the sheet directly as a body, with a resolved ledger.
  Future<void> pumpSheet(
    WidgetTester tester, {
    required DriverEarningsSummary earnings,
  }) async {
    when(() => repo.fetchEarnings()).thenAnswer((_) async => earnings);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [payoutRepositoryProvider.overrideWith((ref) => repo)],
        child: const MaterialApp(home: Scaffold(body: WithdrawSheet())),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> enterAmount(WidgetTester tester, String amount) async {
    await tester.enterText(find.byKey(const Key('withdraw-amount')), amount);
    await tester.pump();
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('withdraw-submit')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the card button opens the sheet showing the available balance', (
    tester,
  ) async {
    await pumpSheet(tester, earnings: ledger(availableCents: 2000));

    expect(
      tester.widget<Text>(find.byKey(const Key('withdraw-available'))).data,
      'USD20.00',
    );
    expect(find.byKey(const Key('withdraw-amount')), findsOneWidget);
    expect(find.byKey(const Key('withdraw-submit')), findsOneWidget);
  });

  testWidgets('an empty amount is rejected locally, never hitting the server', (
    tester,
  ) async {
    await pumpSheet(tester, earnings: ledger());

    await submit(tester);

    expect(find.text('Enter an amount greater than zero.'), findsOneWidget);
    verifyNever(
      () => repo.requestWithdrawal(
        amountCents: any(named: 'amountCents'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
  });

  testWidgets('an amount below the minimum is rejected locally', (tester) async {
    await pumpSheet(tester, earnings: ledger());

    // 1.00 < the documented 5.00 (500 cents) minimum.
    await enterAmount(tester, '1.00');
    await submit(tester);

    expect(find.text('Minimum withdrawal is USD5.00.'), findsOneWidget);
    verifyNever(
      () => repo.requestWithdrawal(
        amountCents: any(named: 'amountCents'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
  });

  testWidgets('an amount above the balance is rejected locally', (tester) async {
    await pumpSheet(tester, earnings: ledger(availableCents: 2000));

    // 100.00 > 20.00 available.
    await enterAmount(tester, '100.00');
    await submit(tester);

    expect(find.text('That is more than your available balance.'), findsOneWidget);
    verifyNever(
      () => repo.requestWithdrawal(
        amountCents: any(named: 'amountCents'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    );
  });

  testWidgets('a 422 renders the server message inline', (tester) async {
    await pumpSheet(tester, earnings: ledger(availableCents: 2000));
    stubWithdraw(
      (_) async => throw _failure(status: 422, message: 'amount too small'),
    );

    await enterAmount(tester, '10.00');
    await submit(tester);

    expect(find.byKey(const Key('withdraw-inline-error')), findsOneWidget);
    expect(find.text('amount too small'), findsOneWidget);
    // The form is still editable; the driver can correct the amount.
    expect(find.byKey(const Key('withdraw-submit')), findsOneWidget);
    // The failed attempt did not clear what the driver typed, so the inline
    // error sits next to the amount it refers to.
    expect(
      tester
          .widget<EditableText>(find.descendant(
            of: find.byKey(const Key('withdraw-amount')),
            matching: find.byType(EditableText),
          ))
          .controller
          .text,
      '10.00',
    );
  });

  testWidgets('a 409 shows the server message and refreshes the balance', (
    tester,
  ) async {
    var fetches = 0;
    when(() => repo.fetchEarnings()).thenAnswer((_) async {
      fetches++;
      return ledger(availableCents: fetches == 1 ? 2000 : 300);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [payoutRepositoryProvider.overrideWith((ref) => repo)],
        child: const MaterialApp(home: Scaffold(body: WithdrawSheet())),
      ),
    );
    await tester.pump();
    await tester.pump();

    stubWithdraw(
      (_) async => throw _failure(status: 409, message: 'insufficient balance'),
    );

    await enterAmount(tester, '20.00');
    await submit(tester);

    expect(find.byKey(const Key('withdraw-conflict')), findsOneWidget);
    expect(find.text('insufficient balance'), findsOneWidget);
    // The conflict path re-read the ledger so the balance is current.
    expect(fetches, 2);
    expect(
      tester.widget<Text>(find.byKey(const Key('withdraw-available'))).data,
      'USD3.00',
    );
  });

  testWidgets('a transport failure offers a Retry that replays the same key', (
    tester,
  ) async {
    await pumpSheet(tester, earnings: ledger());
    final keys = <String>[];
    stubWithdraw((key) async {
      keys.add(key);
      throw _transport();
    });

    await enterAmount(tester, '10.00');
    await submit(tester);

    expect(find.byKey(const Key('withdraw-transport-error')), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('withdraw-transport-error')),
        matching: find.byType(TextButton),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(keys, hasLength(2));
    // Replaying the key is what stops an ambiguous failure from double-debiting.
    expect(keys[0], keys[1]);
  });

  testWidgets('a successful withdrawal shows the pending ledger copy', (
    tester,
  ) async {
    await pumpSheet(tester, earnings: ledger(availableCents: 2000));
    stubWithdraw(
      (_) async => WithdrawalResult(
        withdrawal: const DriverWithdrawal(status: 'pending', amountCents: -1000),
        earnings: ledger(availableCents: 1000),
      ),
    );

    await enterAmount(tester, '10.00');
    await submit(tester);

    expect(find.byKey(const Key('withdraw-pending')), findsOneWidget);
    // The copy must not claim money moved — it is a recorded ledger debit.
    expect(find.textContaining('no money has moved'), findsOneWidget);
    expect(find.byKey(const Key('withdraw-done')), findsOneWidget);
  });

  testWidgets('showWithdrawSheet opens the sheet as a modal from a caller', (
    tester,
  ) async {
    when(() => repo.fetchEarnings()).thenAnswer((_) async => ledger());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [payoutRepositoryProvider.overrideWith((ref) => repo)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => showWithdrawSheet(context, ref),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(WithdrawSheet), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reopening after a success shows a fresh form, not the pending copy',
      (tester) async {
    when(() => repo.fetchEarnings()).thenAnswer((_) async => ledger());
    stubWithdraw(
      (_) async => WithdrawalResult(
        withdrawal: const DriverWithdrawal(status: 'pending', amountCents: -1000),
        earnings: ledger(availableCents: 1000),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [payoutRepositoryProvider.overrideWith((ref) => repo)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => ElevatedButton(
                onPressed: () => showWithdrawSheet(context, ref),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // First open → withdraw → pending copy.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('withdraw-amount')), '10.00');
    await tester.tap(find.byKey(const Key('withdraw-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('withdraw-pending')), findsOneWidget);

    // Close via Done, then reopen: the global controller must not leave the
    // sheet stuck on the previous attempt's result.
    await tester.tap(find.byKey(const Key('withdraw-done')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('withdraw-pending')), findsNothing);
    expect(find.byKey(const Key('withdraw-amount')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a typed 10.00 posts exactly 1000 cents', (tester) async {
    await pumpSheet(tester, earnings: ledger(availableCents: 2000));
    final amounts = <int>[];
    when(
      () => repo.requestWithdrawal(
        amountCents: any(named: 'amountCents'),
        idempotencyKey: any(named: 'idempotencyKey'),
      ),
    ).thenAnswer((inv) async {
      amounts.add(inv.namedArguments[#amountCents] as int);
      return WithdrawalResult(
        withdrawal: const DriverWithdrawal(status: 'pending', amountCents: -1000),
        earnings: ledger(availableCents: 1000),
      );
    });

    await enterAmount(tester, '10.00');
    await submit(tester);

    // Major units are converted to integer cents exactly once, at the boundary.
    expect(amounts, [1000]);
  });

  testWidgets('the success copy does not branch on withdrawal.status', (
    tester,
  ) async {
    // The server only ever records `pending`, so the sheet's success copy is
    // unconditional: `status` is parsed but not rendered (see the plan/repo
    // notes). This characterization guard keeps the copy from ever drifting
    // toward "money moved" for a status the server cannot send today.
    await pumpSheet(tester, earnings: ledger(availableCents: 2000));
    stubWithdraw(
      (_) async => WithdrawalResult(
        withdrawal:
            const DriverWithdrawal(status: 'completed', amountCents: -1000),
        earnings: ledger(availableCents: 1000),
      ),
    );

    await enterAmount(tester, '10.00');
    await submit(tester);

    expect(find.byKey(const Key('withdraw-pending')), findsOneWidget);
    expect(find.textContaining('no money has moved'), findsOneWidget);
  });
}
