import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../../payout/model/driver_earnings.dart';
import '../../payout/presentation/withdraw_sheet.dart';
import '../../payout/providers/payout_providers.dart';
import '../data/rated_rides_provider.dart';
import '../providers/history_provider.dart';
import 'rate_sheet.dart';

/// Completed-trip history plus the driver's earnings ledger (US-D11).
///
/// The earnings card is the **server's** ledger (`GET /driver/me/earnings`,
/// integer cents), not a sum over the loaded rides: the balance and the
/// withdraw CTA live next to the fares that produced them. A withdrawal is a
/// recorded pending debit, not a bank transfer, and the sheet says so.
class RidesHistoryScreen extends ConsumerStatefulWidget {
  const RidesHistoryScreen({super.key});

  @override
  ConsumerState<RidesHistoryScreen> createState() => _RidesHistoryScreenState();
}

class _RidesHistoryScreenState extends ConsumerState<RidesHistoryScreen> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ref.read(historyProvider.notifier).refresh(),
    );
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Fetches the next page when the driver gets within 300 px of the bottom.
  /// [HistoryNotifier.loadMore] collapses repeats, so this can fire freely.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 300) {
      ref.read(historyProvider.notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final history = ref.watch(historyProvider);
    final earnings = ref.watch(earningsProvider);
    final ratedRides = ref.watch(ratedRidesProvider);

    // One refresh covers all three: the ride page, which of those rides are
    // already rated, and the ledger balance the withdraw sheet checks against.
    Future<void> refreshAll() => Future.wait([
      ref.read(historyProvider.notifier).refresh(silent: true),
      ref.read(ratedRidesProvider.notifier).refresh(),
      ref.read(earningsProvider.notifier).refresh(),
    ]);

    // Body-only: `DriverShell` owns the Scaffold/AppBar for the section. The
    // AppBar's refresh action moves into the body so the control survives the
    // chrome handover (pull-to-refresh remains as well).
    final topContent = <Widget>[
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, right: 8),
          child: IconButton(
            key: const Key('history-refresh'),
            tooltip: 'Refresh',
            onPressed: history.loading ? null : refreshAll,
            icon: const Icon(Icons.refresh),
          ),
        ),
      ),
      _EarningsCard(earnings: earnings),
      if (history.error != null)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: AppErrorRow(
            key: const Key('error-retry'),
            message: history.error!,
            onRetry: () => ref.read(historyProvider.notifier).refresh(),
          ),
        ),
      // A rated list that failed to load leaves every prompt below in
      // `unknown`: silently offering them again is the bug this replaces,
      // so say what happened and let the driver retry instead.
      if (ratedRides.hasError)
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: AppErrorRow(
            key: const Key('error-retry'),
            message: ratedRidesErrorMessage,
            onRetry: () => ref.read(ratedRidesProvider.notifier).refresh(),
          ),
        ),
    ];

    // Empty history: `AppEmptyState` is the `RefreshIndicator`'s own scrollable.
    // Nested inside the history `ListView` (as it was) an inner scrollable
    // swallowed a pull on the empty copy at notification depth 1, so the
    // enclosing `RefreshIndicator` never fired. The top content rides in the
    // empty state's `header` so the surface stays a single scrollable.
    if (history.rides.isEmpty && !history.loading) {
      return RefreshIndicator(
        onRefresh: refreshAll,
        child: AppEmptyState(
          icon: Icons.receipt_long,
          message: 'No trips yet',
          description: 'Completed trips and your fares will show up here.',
          topSpacing: AppSpacing.xl,
          header: Column(mainAxisSize: MainAxisSize.min, children: topContent),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: refreshAll,
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          ...topContent,
          if (history.loading && history.rides.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            for (final ride in history.rides) _RideTile(ride: ride),
            if (history.loadingMore)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!history.hasMore && history.rides.length > 1)
              const _EndOfList(),
          ],
        ],
      ),
    );
  }
}

/// The driver's earnings ledger, backed by `GET /driver/me/earnings`.
///
/// Money arrives as integer cents and is converted exactly once, at render,
/// through [formatCents]; a null currency renders bare. A loading card shows a
/// spinner rather than a fabricated `0.00`.
class _EarningsCard extends ConsumerWidget {
  final AsyncValue<DriverEarningsSummary> earnings;

  const _EarningsCard({required this.earnings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // `valueOrNull` keeps the resolved summary on screen across a refresh.
    final summary = earnings.valueOrNull;

    if (summary == null) {
      return AppCard(
        margin: const EdgeInsets.all(AppSpacing.lg),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: earnings.hasError
            ? AppErrorRow(
                key: const Key('earnings-error'),
                message: earningsErrorMessage,
                onRetry: () =>
                    ref.read(earningsProvider.notifier).refresh(),
              )
            : const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
      );
    }

    final currency = summary.currency;
    final canWithdraw = summary.availableCents > 0;

    return AppCard(
      margin: const EdgeInsets.all(AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Available to withdraw', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            key: const Key('earnings-available'),
            formatCents(summary.availableCents, currency: currency),
            style: theme.textTheme.headlineMedium,
          ),
          const SizedBox(height: 4),
          AppButton(
            key: const Key('withdraw-button'),
            label: 'Withdraw',
            variant: AppButtonVariant.secondary,
            onPressed: canWithdraw
                ? () => showWithdrawSheet(context, ref)
                : null,
          ),
          if (!canWithdraw)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'No balance is available to withdraw yet.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const Divider(height: 24),
          Text('Fares this month', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            key: const Key('earnings-month-total'),
            formatCents(summary.monthTotalCents, currency: currency),
            style: theme.textTheme.headlineSmall,
          ),
          Text(
            summary.monthTrips == 1
                ? '1 completed trip'
                : '${summary.monthTrips} completed trips',
            style: theme.textTheme.bodySmall,
          ),
          if (summary.months.isNotEmpty) ...[
            const Divider(height: 24),
            for (final month in summary.months)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(month.label, style: theme.textTheme.bodyMedium),
                    Text(
                      '${month.trips} · '
                      '${formatCents(month.totalCents, currency: currency)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
          ],
          const Divider(height: 24),
          _ledgerRow(theme, 'Pending', summary.pendingCents, currency,
              const Key('earnings-pending')),
          _ledgerRow(theme, 'Withdrawn', summary.withdrawnCents, currency,
              const Key('earnings-withdrawn')),
          _ledgerRow(theme, 'Lifetime', summary.lifetimeCents, currency,
              const Key('earnings-lifetime')),
          const SizedBox(height: 8),
          // The honest caveat: a withdrawal is a recorded ledger debit, not a
          // bank transfer. Money does not move until payouts are processed.
          Text(
            'Withdrawals are recorded as pending ledger entries. '
            'No money moves until payouts are processed.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _ledgerRow(
    ThemeData theme,
    String label,
    int cents,
    String? currency,
    Key key,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            key: key,
            formatCents(cents, currency: currency),
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _RideTile extends ConsumerWidget {
  final Ride ride;

  const _RideTile({required this.ride});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final completed = ride.status == 'completed';
    // Tri-state, not a bool: while the list loads — and after a failed load —
    // this is `unknown`, and the tile shows neither a prompt nor a "Rated"
    // claim. The server already knows which rides are rated, so a cold start
    // does not re-prompt for old trips. `valueOrNull` keeps the resolved answer
    // readable across a refresh; a not-yet-resolved future is `unknown`.
    final status =
        ref.watch(ratedRideStatusProvider(ride.id)).valueOrNull ??
        RatingStatus.unknown;
    final when = _rideDate(ride);
    // A cancelled trip paid nothing; grey it out rather than showing a fare it
    // never earned.
    final dimmed = ride.status == 'cancelled';

    return AppListTile(
      key: Key('ride-tile-${ride.id}'),
      leading: Icon(
        completed ? Icons.check_circle : Icons.cancel,
        color: completed ? AppColors.success : AppColors.muted,
      ),
      title: Text(
        '${ride.pickupAddress ?? 'Pickup'} → ${ride.dropoffAddress ?? 'Dropoff'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: dimmed
            ? theme.textTheme.bodyLarge?.copyWith(color: AppColors.muted)
            : theme.textTheme.bodyLarge,
      ),
      subtitle: Text(
        [
          when == null ? 'Date unknown' : _formatDate(when),
          _statusLabel(ride),
        ].join(' · '),
        style: theme.textTheme.bodySmall,
      ),
      trailing: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            completed && ride.totalFare != null
                ? formatMoney(ride.totalFare!, currency: ride.fareCurrency)
                : '—',
            style: theme.textTheme.titleMedium?.copyWith(
              color: dimmed ? AppColors.muted : null,
            ),
          ),
          // Only a completed ride can be rated, and only once — as far as the
          // server's list says.
          if (completed && status.canPrompt)
            // Shrink-wrapped: a default Material button is 48px tall, which
            // together with the fare overflows the ListTile's trailing slot.
            TextButton(
              key: Key('rate-button-${ride.id}'),
              onPressed: () => showRateSheet(context, ref, rideId: ride.id),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Rate'),
            )
          else if (status == RatingStatus.rated)
            Text(
              'Rated',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.success,
              ),
            ),
        ],
      ),
    );
  }

  /// `completed_at` first, `requested_at` as the fallback, matching the
  /// ledger's month bucketing so a tile and its month always agree.
  static DateTime? _rideDate(Ride ride) {
    for (final raw in [ride.completedAt, ride.requestedAt]) {
      if (raw == null || raw.isEmpty) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.toLocal();
    }
    return null;
  }

  /// `Sep 25, 2026, 14:03` — hand-rolled, `intl` is not a dependency.
  static String _formatDate(DateTime value) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = value.hour.toString().padLeft(2, '0');
    final mm = value.minute.toString().padLeft(2, '0');
    return '${months[value.month - 1]} ${value.day}, ${value.year}, $hh:$mm';
  }

  static String _statusLabel(Ride ride) => switch (ride.status) {
    'completed' => 'Completed',
    'cancelled' =>
      ride.cancelledBy == null
          ? 'Cancelled'
          : 'Cancelled by ${ride.cancelledBy == 'rider' ? 'rider' : ride.cancelledBy}',
    _ => ride.status,
  };
}

class _EndOfList extends StatelessWidget {
  const _EndOfList();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text(
          'That is every trip.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}
