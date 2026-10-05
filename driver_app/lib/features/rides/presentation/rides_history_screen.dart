import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../data/rated_rides_provider.dart';
import '../providers/history_provider.dart';
import 'rate_sheet.dart';

/// Completed-trip history with client-side earnings (US-D11).
///
/// The earnings card is a sum over the rides loaded so far, **not** a server
/// figure: `GET /driver/me/earnings` and `POST /driver/earnings/withdraw` are
/// stubs, so there is nothing honest to call for an all-time balance and the
/// card says so. The same rule is why there is no withdraw button here.
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

    // One refresh covers both lists: which rides are completed and which of
    // them are already rated have to agree, and they arrive from two endpoints.
    Future<void> refreshAll() => Future.wait([
          ref.read(historyProvider.notifier).refresh(silent: true),
          ref.read(ratedRidesProvider.notifier).refresh(),
        ]);

    // Body-only: `DriverShell` owns the Scaffold/AppBar for the section. The
    // AppBar's refresh action moves into the body so the control survives the
    // chrome handover (pull-to-refresh remains as well).
    return RefreshIndicator(
      onRefresh: refreshAll,
      child: ListView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
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
          _EarningsCard(summary: earnings, total: history.total),
          if (history.error != null)
            _ErrorRow(
              message: history.error!,
              onRetry: () => ref.read(historyProvider.notifier).refresh(),
            ),
          // A rated list that failed to load leaves every prompt below in
          // `unknown`: silently offering them again is the bug this replaces,
          // so say what happened and let the driver retry instead.
          if (ratedRides.hasError)
            _ErrorRow(
              message: ratedRidesErrorMessage,
              onRetry: () => ref.read(ratedRidesProvider.notifier).refresh(),
            ),
          if (history.loading && history.rides.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (history.rides.isEmpty)
            const _EmptyState()
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

class _EarningsCard extends StatelessWidget {
  final EarningsSummary summary;
  final int total;

  const _EarningsCard({required this.summary, required this.total});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fares this month', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              key: const Key('earnings-month-total'),
              '\$${summary.monthTotal.toStringAsFixed(2)}',
              style: theme.textTheme.headlineMedium,
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
                        '${month.trips} · \$${month.total.toStringAsFixed(2)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            // The honest caveat: the server's earnings endpoints are stubs, so
            // this covers the pages loaded, not the driver's whole book.
            Text(
              'Sum of fares on the ${summary.completedTrips} completed '
              '${summary.completedTrips == 1 ? 'trip' : 'trips'} loaded so far'
              '${total > summary.completedTrips ? ' of $total' : ''}. '
              'Withdrawals are not available yet.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
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
    // does not re-prompt for old trips.
    final status = ref.watch(ratedRideStatusProvider(ride.id));
    final when = _rideDate(ride);
    // A cancelled trip paid nothing; grey it out rather than showing a fare it
    // never earned.
    final dimmed = ride.status == 'cancelled';

    return ListTile(
      key: Key('ride-tile-${ride.id}'),
      leading: Icon(
        completed ? Icons.check_circle : Icons.cancel,
        color: completed ? Colors.green : Colors.grey,
      ),
      title: Text(
        '${ride.pickupAddress ?? 'Pickup'} → ${ride.dropoffAddress ?? 'Dropoff'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: dimmed
            ? theme.textTheme.bodyLarge?.copyWith(color: Colors.grey)
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
                ? '\$${ride.totalFare!.toStringAsFixed(2)}'
                : '—',
            style: theme.textTheme.titleMedium?.copyWith(
              color: dimmed ? Colors.grey : null,
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
              style: theme.textTheme.labelSmall?.copyWith(color: Colors.green),
            ),
        ],
      ),
    );
  }

  /// `completed_at` first, `requested_at` as the fallback, matching
  /// [EarningsSummary]'s bucketing so a tile and its month always agree.
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Column(
        children: [
          Icon(
            Icons.receipt_long,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text('No trips yet', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Completed trips and your fares will show up here.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorRow({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            key: const Key('error-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
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
