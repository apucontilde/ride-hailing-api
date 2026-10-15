import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../model/driver_earnings.dart';
import '../payout_config.dart';
import '../providers/payout_providers.dart';

/// Opens the withdraw sheet as a modal bottom sheet, mirroring `showRateSheet`.
///
/// The submit state is reset for a fresh open (the controller outlives the
/// sheet), while an unresolved attempt's idempotency key is preserved so a
/// reopened same-amount retry replays instead of double-debiting.
Future<void> showWithdrawSheet(BuildContext context, WidgetRef ref) {
  ref.read(withdrawControllerProvider.notifier).present();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: const WithdrawSheet(),
    ),
  );
}

/// Amount entry → `POST /driver/earnings/withdraw`.
///
/// A withdrawal here is a **recorded pending ledger debit, not a bank
/// transfer**: the success copy says the request is pending and that no money
/// has moved yet. A `422` renders inline under the field and keeps the entered
/// amount so the driver can correct it; a `409` shows the server's message and
/// refreshes the balance; a transport failure / `5xx` offers a Retry that
/// reuses the same idempotency key.
class WithdrawSheet extends ConsumerStatefulWidget {
  const WithdrawSheet({super.key});

  @override
  ConsumerState<WithdrawSheet> createState() => _WithdrawSheetState();
}

class _WithdrawSheetState extends ConsumerState<WithdrawSheet> {
  final TextEditingController _amount = TextEditingController();
  String? _localError;

  @override
  void initState() {
    super.initState();
    // Editing the field clears a stale local validation error.
    _amount.addListener(_clearLocalError);
  }

  @override
  void dispose() {
    _amount.removeListener(_clearLocalError);
    _amount.dispose();
    super.dispose();
  }

  void _clearLocalError() {
    if (_localError != null && mounted) {
      setState(() => _localError = null);
    }
  }

  /// The entered major-unit amount as integer cents, or `null` when it does not
  /// parse. Money is converted exactly once, here.
  int? _enteredCents() {
    final text = _amount.text.trim().replaceAll(',', '');
    if (text.isEmpty) return null;
    final major = double.tryParse(text);
    if (major == null) return null;
    return (major * 100).round();
  }

  Future<void> _submit(DriverEarningsSummary? summary) async {
    final cents = _enteredCents();
    if (cents == null || cents <= 0) {
      setState(() => _localError = 'Enter an amount greater than zero.');
      return;
    }
    if (cents < payoutMinWithdrawCents) {
      setState(
        () => _localError = 'Minimum withdrawal is '
            '${formatCents(payoutMinWithdrawCents, currency: summary?.currency)}.',
      );
      return;
    }
    final available = summary?.availableCents;
    if (available != null && cents > available) {
      setState(
        () => _localError = 'That is more than your available balance.',
      );
      return;
    }
    setState(() => _localError = null);
    await ref
        .read(withdrawControllerProvider.notifier)
        .submit(amountCents: cents);
  }

  @override
  Widget build(BuildContext context) {
    // Keep the resolved summary readable across a refresh (the 409 path
    // refetches it), exactly as the card does.
    final summary = ref.watch(earningsProvider).valueOrNull;
    final withdraw = ref.watch(withdrawControllerProvider);

    if (withdraw.isSubmitted) return _pending(context);

    final validationError = _localError ??
        (withdraw.errorKind == WithdrawErrorKind.validation
            ? withdraw.message
            : null);

    return AppBottomSheet(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSheetHandle(),
          const SizedBox(height: AppSpacing.lg),
          Text('Withdraw', textAlign: TextAlign.center, style: AppTextStyles.title),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Available to withdraw',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.muted),
          ),
          Text(
            key: const Key('withdraw-available'),
            formatCents(summary?.availableCents ?? 0, currency: summary?.currency),
            textAlign: TextAlign.center,
            style: AppTextStyles.title,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            key: const Key('withdraw-amount'),
            controller: _amount,
            label: 'Amount',
            hint: '0.00',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.done,
          ),
          if (validationError != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              validationError,
              key: const Key('withdraw-inline-error'),
              style: AppTextStyles.body.copyWith(color: AppColors.danger),
            ),
          ],
          if (withdraw.errorKind == WithdrawErrorKind.conflict &&
              withdraw.message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppErrorRow(
              key: const Key('withdraw-conflict'),
              message: withdraw.message!,
            ),
          ],
          if (withdraw.errorKind == WithdrawErrorKind.transport &&
              withdraw.message != null) ...[
            const SizedBox(height: AppSpacing.sm),
            AppErrorRow(
              key: const Key('withdraw-transport-error'),
              message: withdraw.message!,
              onRetry: () =>
                  ref.read(withdrawControllerProvider.notifier).retry(),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            key: const Key('withdraw-submit'),
            label: 'Withdraw',
            expand: true,
            isLoading: withdraw.isSubmitting,
            onPressed: withdraw.isSubmitting ? null : () => _submit(summary),
          ),
        ],
      ),
    );
  }

  Widget _pending(BuildContext context) {
    return AppBottomSheet(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppSheetHandle(),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Withdrawal requested',
            key: const Key('withdraw-pending'),
            textAlign: TextAlign.center,
            style: AppTextStyles.title,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Your withdrawal is pending and no money has moved yet. '
            'Payouts are processed separately.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppButton(
            key: const Key('withdraw-done'),
            label: 'Done',
            expand: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
