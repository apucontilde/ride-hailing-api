import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../data/history_provider.dart';
import '../model/ride_summary.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(historyProvider.notifier).firstPage();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      ref.read(historyProvider.notifier).loadMore();
    }
  }

  Future<void> _refresh() => ref.read(historyProvider.notifier).firstPage();

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(historyProvider);
    // Body-only: `RiderShell` owns the `Scaffold` + `AppBar` + drawer.
    return RefreshIndicator(onRefresh: _refresh, child: _buildBody(state));
  }

  Widget _buildBody(HistoryState state) {
    if (state.isLoading && state.rides.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null && state.rides.isEmpty) {
      return AppErrorState(
        message: state.error!,
        onRetry: () => ref.read(historyProvider.notifier).firstPage(),
      );
    }
    if (state.rides.isEmpty) {
      return const AppEmptyState(icon: Icons.history, message: 'No rides yet');
    }
    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: state.rides.length + (state.isLoadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == state.rides.length) {
          return const Padding(
            padding: EdgeInsets.all(AppSpacing.lg),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return _RideHistoryTile(ride: state.rides[index]);
      },
    );
  }
}

class _RideHistoryTile extends StatelessWidget {
  final RideSummary ride;

  const _RideHistoryTile({required this.ride});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${ride.pickupAddress} \u2192 ${ride.dropoffAddress}',
                  style: AppTextStyles.body.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                ride.status,
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.mutedStrong,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Text(
                ride.vehicleType,
                style: AppTextStyles.label.copyWith(
                  color: AppColors.mutedStrong,
                  fontWeight: FontWeight.w400,
                ),
              ),
              const Spacer(),
              Text(
                '\$${ride.totalFare.toStringAsFixed(2)}',
                style: AppTextStyles.body.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _timestamps(ride),
            style: AppTextStyles.caption.copyWith(
              color: AppColors.mutedFaint,
            ),
          ),
        ],
      ),
    );
  }

  String _timestamps(RideSummary ride) {
    final requested = _formatTimestamp(ride.requestedAt);
    final completed = _formatTimestamp(ride.completedAt);
    if (requested.isEmpty && completed.isEmpty) return '';
    if (completed.isEmpty) return requested;
    return '$requested \u2192 $completed';
  }

  String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
