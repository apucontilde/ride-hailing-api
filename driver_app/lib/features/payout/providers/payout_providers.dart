import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../../../core/api/api_exceptions.dart';
import '../data/payout_repository.dart';
import '../model/driver_earnings.dart';

/// Shown in place of the earnings card when the summary could not be loaded.
const String earningsErrorMessage = 'Could not load your earnings.';

/// The endpoint-backed driver earnings.
///
/// Lazy and non-autoDispose, exactly like `ratedRidesProvider`: it fetches when
/// a watching screen mounts (the history card) and keeps the resolved summary
/// readable across a refresh. This is the sole earnings source — it does **not**
/// read `historyProvider` and derives nothing from loaded rides (the old
/// client-side sum over rides is retired).
class EarningsNotifier extends AsyncNotifier<DriverEarningsSummary> {
  @override
  Future<DriverEarningsSummary> build() {
    return ref.read(payoutRepositoryProvider).fetchEarnings();
  }

  /// Re-reads the endpoint. The current summary stays readable while the
  /// request runs, so a pull-to-refresh never blanks the balance.
  Future<void> refresh() async {
    final previous = state;
    state = const AsyncValue<DriverEarningsSummary>.loading()
        .copyWithPrevious(previous);
    final result = await AsyncValue.guard(
      () => ref.read(payoutRepositoryProvider).fetchEarnings(),
    );
    state = result.copyWithPrevious(previous);
  }

  /// Adopts a summary the server already returned (the withdraw response
  /// carries the updated one), so the balance moves without a second request.
  void apply(DriverEarningsSummary summary) {
    state = AsyncValue<DriverEarningsSummary>.data(summary);
  }
}

final earningsProvider =
    AsyncNotifierProvider<EarningsNotifier, DriverEarningsSummary>(
  EarningsNotifier.new,
);

/// Where a withdrawal attempt is in its lifecycle.
enum WithdrawPhase {
  /// Nothing submitted, or the form was reset.
  idle,

  /// A request is in flight; a second submit is a no-op.
  submitting,

  /// The server recorded a pending withdrawal.
  submitted,

  /// The attempt failed; [WithdrawState.errorKind] says of what kind.
  error,
}

/// What the failed attempt means for the form.
enum WithdrawErrorKind {
  /// `422 VALIDATION_ERROR` — the amount was rejected. Inline under the field.
  validation,

  /// `409 CONFLICT` — the balance moved under the driver. Show the server's
  /// message, refresh the summary and re-enable the form.
  conflict,

  /// Transport failure or `5xx` — ambiguous (the server may have written), so a
  /// retry must replay the **same** idempotency key.
  transport,
}

class WithdrawState {
  final WithdrawPhase phase;
  final String? message;
  final WithdrawErrorKind? errorKind;

  const WithdrawState({
    this.phase = WithdrawPhase.idle,
    this.message,
    this.errorKind,
  });

  bool get isSubmitting => phase == WithdrawPhase.submitting;
  bool get isSubmitted => phase == WithdrawPhase.submitted;
}

/// Owns one withdrawal attempt: submit state plus the **idempotency-key
/// lifecycle**.
///
/// One key per attempt, reused for every retry of that attempt; cleared after a
/// terminal `4xx` (the server definitively rejected before writing) and after
/// any `2xx`, so the next withdrawal is a new request. It mirrors the rider's
/// create-ride `_attemptKey` seam.
class WithdrawController extends StateNotifier<WithdrawState> {
  WithdrawController(this._ref) : super(const WithdrawState());

  final Ref _ref;

  /// The key for the attempt in flight, plus the amount it was opened for.
  String? _attemptKey;
  int? _attemptAmount;

  /// Whether a fresh submit would replay the previous attempt's key (same
  /// amount) or open a new one. Exposed for tests/telemetry only.
  String? get attemptKey => _attemptKey;

  Future<void> submit({required int amountCents}) async {
    // A double-tap, or a submit while one is in flight, is a no-op: the server
    // must see exactly one request per attempt.
    if (state.isSubmitting) return;

    // Reuse the key only for a replay of the same amount; an edited amount is a
    // new attempt and needs a new key (otherwise the server would replay the
    // old withdrawal amount).
    if (_attemptKey == null || _attemptAmount != amountCents) {
      _attemptKey = generateWithdrawKey();
      _attemptAmount = amountCents;
    }

    state = const WithdrawState(phase: WithdrawPhase.submitting);
    try {
      final result = await _ref
          .read(payoutRepositoryProvider)
          .requestWithdrawal(
            amountCents: amountCents,
            idempotencyKey: _attemptKey!,
          );
      // Definitive success: the next withdrawal is a new request.
      _clearAttempt();
      _ref.read(earningsProvider.notifier).apply(result.earnings);
      state = const WithdrawState(phase: WithdrawPhase.submitted);
    } on DioException catch (e) {
      final mapped = e.error;
      final status = mapped is ApiException
          ? mapped.statusCode
          : e.response?.statusCode;
      // A terminal 4xx was rejected before any write, so the attempt is spent.
      // A transport failure / 5xx may have written, so keep the key to replay.
      final terminal = status != null && status >= 400 && status < 500;
      if (terminal) _clearAttempt();

      final kind = switch (status) {
        409 => WithdrawErrorKind.conflict,
        422 => WithdrawErrorKind.validation,
        _ => WithdrawErrorKind.transport,
      };
      if (kind == WithdrawErrorKind.conflict) {
        // The balance moved under the driver; re-read it before they retry.
        await _ref.read(earningsProvider.notifier).refresh();
      }
      state = WithdrawState(
        phase: WithdrawPhase.error,
        message: apiErrorMessage(
          e,
          'Could not request your withdrawal. Please try again.',
        ),
        errorKind: kind,
      );
    } catch (_) {
      // Unknown failure: keep the key, so a retry replays rather than
      // double-debits.
      state = const WithdrawState(
        phase: WithdrawPhase.error,
        message: 'Could not request your withdrawal. Please try again.',
        errorKind: WithdrawErrorKind.transport,
      );
    }
  }

  /// Retries the last attempt, reusing its idempotency key and amount.
  Future<void> retry() async {
    final amount = _attemptAmount;
    if (amount == null) return;
    await submit(amountCents: amount);
  }

  /// Puts the controller back into its blank form state for a freshly opened
  /// sheet, **without** touching the attempt key/amount.
  ///
  /// The controller outlives the sheet (it is a global non-autoDispose
  /// provider), so without this a reopen after a success would show the
  /// "pending" copy and a reopen after a failure would show the stale error.
  /// Keeping the key is the point: an ambiguous (transport/5xx) attempt that
  /// the driver closed and reopened must still replay rather than double-debit
  /// when the same amount is resubmitted.
  void present() {
    state = const WithdrawState();
  }

  void _clearAttempt() {
    _attemptKey = null;
    _attemptAmount = null;
  }
}

final withdrawControllerProvider =
    StateNotifierProvider<WithdrawController, WithdrawState>(
  WithdrawController.new,
);

final _random = Random();

/// One key per attempt: `<millisSinceEpoch>-<random>`; no uuid dependency.
String generateWithdrawKey() {
  return '${DateTime.now().millisecondsSinceEpoch}-${_randomString(8)}';
}

String _randomString(int length) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List.generate(length, (_) => chars[_random.nextInt(chars.length)])
      .join();
}
