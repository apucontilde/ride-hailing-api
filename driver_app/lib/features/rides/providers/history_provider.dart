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

/// One month of completed fares.
class EarningsMonth {
  /// The first instant of the month, for sorting and comparison.
  final DateTime month;
  final double total;
  final int trips;

  /// The single ISO-4217 code every completed trip in this month was priced in
  /// (`USD`, `CRC`, ...), or `null` when the month's rides carry no currency at
  /// all (booked before region pricing) or disagree on one. `null` renders the
  /// bare amount rather than inventing a symbol — see [formatMoney].
  final String? currency;

  const EarningsMonth({
    required this.month,
    required this.total,
    required this.trips,
    this.currency,
  });

  /// e.g. `September 2026`. Hand-rolled because `intl` is not a dependency.
  String get label => '${_monthNames[month.month - 1]} ${month.year}';

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}

/// Client-side earnings.
///
/// The backend's `GET /driver/me/earnings` and `POST /driver/earnings/withdraw`
/// are **stubs**, and `GET /driver/ratings` is one too, so nothing here may
/// depend on them: the totals are a sum over the rides the app has loaded. If
/// the backend ever ships real earnings, swap [earningsProvider]'s source and
/// keep this display contract.
class EarningsSummary {
  /// Fares from trips that completed in the current calendar month.
  final double monthTotal;
  final int monthTrips;

  /// Fares from every completed trip loaded so far, across all months.
  final double loadedTotal;
  final int completedTrips;

  /// Newest month first.
  final List<EarningsMonth> months;

  /// The single ISO-4217 code every completed ride was priced in, or `null`
  /// when the loaded rides carry no currency or span more than one. The
  /// aggregate is a sum over the loaded rides, so a driver who drove in one
  /// region gets that region's code on the card; a driver whose loaded fares
  /// disagree (multi-region) gets no symbol rather than a fabricated one,
  /// because adding mixed currencies has no single honest unit. Render through
  /// [formatMoney], which omits the symbol when this is `null`.
  final String? currency;

  const EarningsSummary({
    required this.monthTotal,
    required this.monthTrips,
    required this.loadedTotal,
    required this.completedTrips,
    required this.months,
    this.currency,
  });

  static const empty = EarningsSummary(
    monthTotal: 0,
    monthTrips: 0,
    loadedTotal: 0,
    completedTrips: 0,
    months: [],
  );

  /// Sums [rides] — only `completed` ones count. A cancelled trip has no
  /// payout, and a ride still in progress has no final fare.
  ///
  /// [now] is injectable so the month boundary is testable.
  factory EarningsSummary.from(List<Ride> rides, {DateTime? now}) {
    final today = (now ?? DateTime.now()).toLocal();
    final accumulators = <String, _MonthAccum>{};
    final currencies = <String>{};
    var monthTotal = 0.0;
    var monthTrips = 0;
    var loadedTotal = 0.0;
    var completedTrips = 0;

    for (final ride in rides) {
      if (ride.status != 'completed') continue;
      completedTrips++;
      final fare = ride.totalFare ?? 0;
      loadedTotal += fare;
      final currency = ride.fareCurrency;
      // A blank code is the pre-region "no currency" case, not a currency.
      if (currency != null && currency.isNotEmpty) currencies.add(currency);
      final at = _rideDate(ride);
      if (at == null) continue;
      final key = '${at.year}-${at.month}';
      final accum = accumulators.putIfAbsent(
        key,
        () => _MonthAccum(DateTime(at.year, at.month)),
      );
      accum.total += fare;
      accum.trips++;
      if (currency != null && currency.isNotEmpty) {
        accum.currencies.add(currency);
      }
      if (at.year == today.year && at.month == today.month) {
        monthTotal += fare;
        monthTrips++;
      }
    }

    final months = accumulators.values
        .map((a) => EarningsMonth(
              month: a.month,
              total: a.total,
              trips: a.trips,
              currency: _soleCurrency(a.currencies),
            ))
        .toList()
      ..sort((a, b) => b.month.compareTo(a.month));

    return EarningsSummary(
      monthTotal: monthTotal,
      monthTrips: monthTrips,
      loadedTotal: loadedTotal,
      completedTrips: completedTrips,
      months: months,
      currency: _soleCurrency(currencies),
    );
  }

  /// The one currency when every given code agrees, otherwise `null`. Zero
  /// codes → `null` (nothing to declare); more than one → `null` (no honest
  /// single unit to print).
  static String? _soleCurrency(Set<String> currencies) =>
      currencies.length == 1 ? currencies.first : null;

  /// When the trip happened. `completed_at` is authoritative; `requested_at` is
  /// the fallback for a row the server stamped without it. `null` when neither
  /// parses — such a ride still counts towards the loaded total, it just cannot
  /// be filed under a month.
  static DateTime? _rideDate(Ride ride) {
    for (final raw in [ride.completedAt, ride.requestedAt]) {
      if (raw == null || raw.isEmpty) continue;
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.toLocal();
    }
    return null;
  }
}

class _MonthAccum {
  final DateTime month;
  final Set<String> currencies = <String>{};
  double total = 0;
  int trips = 0;

  _MonthAccum(this.month);
}

/// Derived earnings, recomputed from whatever history is loaded.
final earningsProvider = Provider<EarningsSummary>((ref) {
  final rides = ref.watch(historyProvider).rides;
  return rides.isEmpty
      ? EarningsSummary.empty
      : EarningsSummary.from(rides);
});
