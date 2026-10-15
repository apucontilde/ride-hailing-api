import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../data/rides_repository.dart';

/// Rides per history request. The server clamps `per_page` to 1..50
/// (`internal/handler/ride.go:155-163`).
const int historyPageSize = 20;

/// The driver's paginated ride history.
class HistoryState {
  /// Newest first, de-duplicated by ride id.
  final List<Ride> rides;

  /// The server's count of *all* their rides, not just the loaded ones.
  final int total;

  /// The highest page fetched so far (`0` before the first load).
  final int page;

  final bool loading;
  final bool loadingMore;
  final String? error;

  /// `false` once the server runs out of rows. Computed at fetch time rather
  /// than from `rides.length < total`, because a ride that fails to parse an
  /// id is dropped from the list while still counting towards `total` — a
  /// `total`-only test would then page forever.
  final bool hasMore;

  const HistoryState({
    this.rides = const [],
    this.total = 0,
    this.page = 0,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.hasMore = true,
  });

  HistoryState copyWith({
    List<Ride>? rides,
    int? total,
    int? page,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    bool? hasMore,
  }) {
    return HistoryState(
      rides: rides ?? this.rides,
      total: total ?? this.total,
      page: page ?? this.page,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : error ?? this.error,
      hasMore: hasMore ?? this.hasMore,
    );
  }
}

/// Loads `GET /driver/rides/history` a page at a time.
class HistoryNotifier extends StateNotifier<HistoryState> {
  HistoryNotifier(this._ref) : super(const HistoryState());

  final Ref _ref;

  /// Loads page 1, replacing what is loaded.
  ///
  /// [silent] keeps the current list on screen instead of dropping it for a
  /// spinner — pull-to-refresh already draws its own indicator, so blanking
  /// the list underneath it just flashes.
  Future<void> refresh({bool silent = false}) async {
    if (state.loading) return;
    state = HistoryState(
      rides: silent ? state.rides : const [],
      total: silent ? state.total : 0,
      loading: true,
      error: silent ? state.error : null,
      hasMore: true,
    );
    await _fetch(1, append: false);
  }

  /// Appends the next page. A no-op while a request is in flight, or once the
  /// server has no more rows — so a scroll listener can call it freely.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    state = state.copyWith(loadingMore: true, clearError: true);
    await _fetch(state.page + 1, append: true);
  }

  Future<void> _fetch(int page, {required bool append}) async {
    try {
      final result = await _ref.read(ridesRepositoryProvider).history(
            page: page,
            perPage: historyPageSize,
          );
      // Page 1 is newest-first (`created_at DESC`) and every later page is
      // older, so an append puts the new rows at the *tail*. A ride can still
      // repeat across a page boundary when one lands mid-scroll: the copy
      // already loaded is the newer one, so it keeps both its value and its
      // position.
      final seen = <String>{};
      final rides = <Ride>[];
      for (final ride in [
        if (append) ...state.rides,
        ...result.rides,
      ]) {
        if (ride.id.isEmpty || !seen.add(ride.id)) continue;
        rides.add(ride);
      }
      state = HistoryState(
        rides: rides,
        total: result.total,
        page: page,
        hasMore: result.rides.length >= historyPageSize,
      );
    } catch (_) {
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        error: 'Could not load your ride history.',
      );
    }
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, HistoryState>((ref) {
  return HistoryNotifier(ref);
});
