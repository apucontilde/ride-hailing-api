import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/features/rides/data/rides_repository.dart';
import 'package:driver_app/features/rides/providers/history_provider.dart';

class MockRidesRepository extends Mock implements RidesRepository {}

Ride completed(
  String id, {
  required double fare,
  String? completedAt,
  String status = 'completed',
  String? currency,
}) {
  return Ride(
    id: id,
    riderId: 'u1',
    status: status,
    pickupAddress: 'Pickup $id',
    dropoffAddress: 'Dropoff $id',
    totalFare: fare,
    fareCurrency: currency,
    completedAt: completedAt,
    requestedAt: '2026-01-01T00:00:00Z',
  );
}

/// A full page, so `hasMore` stays open and `loadMore` is allowed to run.
List<Ride> fullPage(String prefix, int count, {int start = 0}) {
  return [
    for (var i = start; i < start + count; i++)
      completed('$prefix$i', fare: 1.0, completedAt: '2026-09-01T10:00:00Z'),
  ];
}

RideHistoryPage page(List<Ride> rides,
    {required int total, int pageNumber = 1}) {
  return RideHistoryPage(
    rides: rides,
    total: total,
    page: pageNumber,
    perPage: historyPageSize,
    totalPages: (total / historyPageSize).ceil(),
  );
}

void main() {
  late MockRidesRepository repo;
  late ProviderContainer container;

  setUp(() {
    repo = MockRidesRepository();
    container = ProviderContainer(
      overrides: [ridesRepositoryProvider.overrideWith((ref) => repo)],
    );
    addTearDown(container.dispose);
  });

  HistoryNotifier history() =>
      container.read(historyProvider.notifier);

  group('HistoryNotifier', () {
    test('starts empty and eager', () {
      final state = container.read(historyProvider);
      expect(state.rides, isEmpty);
      expect(state.total, 0);
      expect(state.page, 0);
      expect(state.hasMore, isTrue);
    });

    test('refresh loads the first page newest-first', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 45),
      );

      await history().refresh();

      final state = container.read(historyProvider);
      expect(state.rides.map((r) => r.id).take(3), ['a0', 'a1', 'a2']);
      expect(state.rides, hasLength(20));
      expect(state.total, 45);
      expect(state.page, 1);
      expect(state.loading, isFalse);
      expect(state.hasMore, isTrue);
    });

    test('a first page shorter than the page size ends the list', () async {
      // A short page is the end of the data, whatever `total` claims — the
      // server reports every row the driver has, including the ones they never
      // saw a rating for.
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 3), total: 3),
      );

      await history().refresh();

      final state = container.read(historyProvider);
      expect(state.rides, hasLength(3));
      expect(state.hasMore, isFalse);
    });

    test('loadMore appends the next page', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 25),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('b', 5, start: 20), total: 25, pageNumber: 2),
      );

      await history().refresh();
      await history().loadMore();

      final state = container.read(historyProvider);
      expect(state.rides, hasLength(25));
      // Page 1 is the newer rides, so it keeps the head of the list.
      expect(state.rides.first.id, 'a0');
      expect(state.rides.last.id, 'b24');
      expect(state.page, 2);
    });

    test('loadMore appends the next page at the tail, still newest-first',
        () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 21),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize)).thenAnswer(
        (_) async => page(
          [
            // Repeated across the boundary, with a stale copy.
            completed('a18', fare: 99, completedAt: '2026-09-02T10:00:00Z'),
            completed('a20', fare: 5, completedAt: '2026-08-02T10:00:00Z'),
          ],
          total: 21,
          pageNumber: 2,
        ),
      );

      await history().refresh();
      await history().loadMore();

      final state = container.read(historyProvider);
      // 20 + 1 genuinely new ride; the repeat is dropped.
      expect(state.rides, hasLength(21));
      // Ordering survives: the appended page is the older one, so it goes last.
      expect(state.rides.first.id, 'a0');
      expect(state.rides.last.id, 'a20');
      expect(state.rides.map((r) => r.id).toSet(), hasLength(21));
      // The already-loaded copy is the newer one and wins.
      expect(state.rides.firstWhere((r) => r.id == 'a18').totalFare, 1.0);
    });

    test('a short page ends the list and loadMore becomes a no-op', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 500),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('b', 3, start: 20), total: 500, pageNumber: 2),
      );

      await history().refresh();
      expect(container.read(historyProvider).hasMore, isTrue);

      await history().loadMore();
      expect(container.read(historyProvider).hasMore, isFalse);
      expect(container.read(historyProvider).rides, hasLength(23));

      await history().loadMore();

      // No third request: the server ran out of rows.
      verifyNever(
        () => repo.history(page: 3, perPage: historyPageSize),
      );
    });

    test('drops rides with no id without paging forever', () async {
      // A row that lost its id still counts towards `total`, so a `total`-only
      // exhaustion test would keep asking for pages. The short page must stop it.
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(
          [
            for (var i = 0; i < 20; i++)
              completed('r$i', fare: 2, completedAt: '2026-09-01T10:00:00Z'),
          ],
          total: 400,
        ),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize)).thenAnswer(
        (_) async => page(
          [Ride(id: '', riderId: 'u1', status: 'completed')],
          total: 400,
          pageNumber: 2,
        ),
      );

      await history().refresh();
      await history().loadMore();
      await history().loadMore();

      final state = container.read(historyProvider);
      expect(state.hasMore, isFalse);
      expect(state.rides, hasLength(20));
    });

    test('concurrent loadMore calls collapse onto one request', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 60),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize)).thenAnswer(
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return page(fullPage('b', 20, start: 20), total: 60, pageNumber: 2);
        },
      );

      await history().refresh();
      await Future.wait([
        history().loadMore(),
        history().loadMore(),
        history().loadMore(),
      ]);

      verify(() => repo.history(page: 2, perPage: historyPageSize)).called(1);
      expect(container.read(historyProvider).rides, hasLength(40));
    });

    test('a second refresh replaces the list rather than appending', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 40),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('b', 20, start: 20), total: 40, pageNumber: 2),
      );

      await history().refresh();
      await history().loadMore();
      expect(container.read(historyProvider).rides, hasLength(40));

      await history().refresh();

      final state = container.read(historyProvider);
      expect(state.rides, hasLength(20));
      expect(state.page, 1);
    });

    test('a refresh replaces a booked value with the completion final',
        () async {
      // Loaded while still open, the row carries the booked quote.
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page([
          Ride(
            id: 'r1',
            riderId: 'u1',
            status: 'in_progress',
            totalFare: 10.0,
            requestedAt: '2026-01-01T00:00:00Z',
          ),
        ], total: 1),
      );
      await history().refresh();
      expect(container.read(historyProvider).rides.single.totalFare, 10.0);

      // It completes with the recomputed final; the refresh picks that up.
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page([
          completed('r1', fare: 13.2, completedAt: '2026-09-01T10:00:00Z'),
        ], total: 1),
      );
      await history().refresh();

      final state = container.read(historyProvider);
      expect(state.rides.single.status, 'completed');
      expect(state.rides.single.totalFare, 13.2);
    });

    test('a silent refresh keeps the list on screen while it reloads',
        () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 3), total: 3),
      );
      await history().refresh();

      var seenDuringReload = 0;
      final subscription = container.listen(
        historyProvider,
        (previous, next) {
          if (next.loading) seenDuringReload = next.rides.length;
        },
        fireImmediately: false,
      );
      addTearDown(subscription.close);

      await history().refresh(silent: true);

      expect(seenDuringReload, 3);
      expect(container.read(historyProvider).loading, isFalse);
    });

    test('a failed pull-to-refresh keeps the loaded rides and shows an error',
        () async {
      // Pull-to-refresh reloads *behind* the list, so a failure there must not
      // cost the driver the history they were reading.
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 20),
      );
      await history().refresh();

      when(() => repo.history(page: 1, perPage: historyPageSize))
          .thenThrow(Exception('boom'));
      await history().refresh(silent: true);

      final state = container.read(historyProvider);
      expect(state.error, isNotNull);
      expect(state.loading, isFalse);
      expect(state.loadingMore, isFalse);
      expect(state.rides, hasLength(20));
    });

    test('a failed first load surfaces an error and an empty list', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize))
          .thenThrow(Exception('boom'));

      await history().refresh();

      final state = container.read(historyProvider);
      expect(state.error, isNotNull);
      expect(state.rides, isEmpty);
      expect(state.loading, isFalse);
    });

    test('a loadMore failure keeps what was already loaded', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page(fullPage('a', 20), total: 40),
      );
      when(() => repo.history(page: 2, perPage: historyPageSize))
          .thenThrow(Exception('boom'));

      await history().refresh();
      await history().loadMore();

      final state = container.read(historyProvider);
      expect(state.error, isNotNull);
      expect(state.rides, hasLength(20));
      expect(state.page, 1);
    });
  });

  group('EarningsSummary', () {
    // Fixed "now" so the month boundary is not a moving target.
    final now = DateTime(2026, 9, 15);

    test('is empty for no rides', () {
      final summary = EarningsSummary.from(const [], now: now);
      expect(summary.monthTotal, 0);
      expect(summary.monthTrips, 0);
      expect(summary.loadedTotal, 0);
      expect(summary.completedTrips, 0);
      expect(summary.months, isEmpty);
    });

    test('buckets fares by the month the trip completed', () {
      final summary = EarningsSummary.from([
        completed('a', fare: 10, completedAt: '2026-09-02T10:00:00Z'),
        completed('b', fare: 15.5, completedAt: '2026-09-20T10:00:00Z'),
        completed('c', fare: 7, completedAt: '2026-08-11T10:00:00Z'),
      ], now: now);

      expect(summary.months, hasLength(2));
      // Newest month first.
      expect(summary.months.first.label, 'September 2026');
      expect(summary.months.first.trips, 2);
      expect(summary.months.first.total, 25.5);
      expect(summary.months.last.label, 'August 2026');
      expect(summary.months.last.trips, 1);

      expect(summary.monthTotal, 25.5);
      expect(summary.monthTrips, 2);
      expect(summary.loadedTotal, 32.5);
      expect(summary.completedTrips, 3);
    });

    test('excludes cancelled and in-progress rides', () {
      final summary = EarningsSummary.from([
        completed('a', fare: 10, completedAt: '2026-09-02T10:00:00Z'),
        completed(
          'b',
          fare: 4,
          completedAt: '2026-09-03T10:00:00Z',
          status: 'cancelled',
        ),
        completed(
          'c',
          fare: 6,
          completedAt: '2026-09-04T10:00:00Z',
          status: 'in_progress',
        ),
      ], now: now);

      expect(summary.completedTrips, 1);
      expect(summary.monthTotal, 10);
      expect(summary.loadedTotal, 10);
    });

    test('carries the single currency every loaded fare agrees on', () {
      final summary = EarningsSummary.from([
        completed(
          'a',
          fare: 10,
          completedAt: '2026-09-02T10:00:00Z',
          currency: 'CRC',
        ),
        completed(
          'b',
          fare: 15.5,
          completedAt: '2026-09-20T10:00:00Z',
          currency: 'CRC',
        ),
      ], now: now);

      expect(summary.currency, 'CRC');
      expect(summary.months.single.currency, 'CRC');
    });

    test('omits the currency when the loaded fares disagree', () {
      final summary = EarningsSummary.from([
        completed(
          'a',
          fare: 10,
          completedAt: '2026-09-02T10:00:00Z',
          currency: 'CRC',
        ),
        completed(
          'b',
          fare: 15.5,
          completedAt: '2026-09-20T10:00:00Z',
          currency: 'USD',
        ),
      ], now: now);

      // Mixed currencies have no single honest unit, so the aggregate claims
      // none rather than printing one region's symbol over another's money.
      expect(summary.currency, isNull);
      expect(summary.months.single.currency, isNull);
    });

    test('no currency at all stays null rather than a guessed default', () {
      final summary = EarningsSummary.from([
        completed('a', fare: 10, completedAt: '2026-09-02T10:00:00Z'),
      ], now: now);

      expect(summary.currency, isNull);
      expect(summary.months.single.currency, isNull);
    });

    test('a blank currency code is not treated as a currency', () {
      final summary = EarningsSummary.from([
        completed(
          'a',
          fare: 10,
          completedAt: '2026-09-02T10:00:00Z',
          currency: 'CRC',
        ),
        completed('b', fare: 5, completedAt: '2026-09-03T10:00:00Z'),
      ], now: now);

      expect(summary.currency, 'CRC');
    });

    test('treats a null fare as zero rather than dropping the trip', () {
      final summary = EarningsSummary.from([
        Ride(
          id: 'a',
          riderId: 'u1',
          status: 'completed',
          completedAt: '2026-09-02T10:00:00Z',
        ),
        completed('b', fare: 3, completedAt: '2026-09-02T10:00:00Z'),
      ], now: now);

      expect(summary.completedTrips, 2);
      expect(summary.monthTrips, 2);
      expect(summary.monthTotal, 3);
    });

    test('falls back to requested_at when completed_at is missing', () {
      final summary = EarningsSummary.from([
        Ride(
          id: 'a',
          riderId: 'u1',
          status: 'completed',
          requestedAt: '2026-07-04T10:00:00Z',
        ),
      ], now: now);

      expect(summary.months.single.label, 'July 2026');
      expect(summary.monthTotal, 0);
      // It is still a completed trip, so it counts towards the loaded total.
      expect(summary.completedTrips, 1);
      expect(summary.loadedTotal, 0);
    });

    test('a trip with no usable date counts but files under no month', () {
      final summary = EarningsSummary.from([
        Ride(id: 'a', riderId: 'u1', status: 'completed', totalFare: 9),
      ], now: now);

      expect(summary.completedTrips, 1);
      expect(summary.loadedTotal, 9);
      expect(summary.months, isEmpty);
      expect(summary.monthTotal, 0);
    });

    test('sums the final charge of completed rides, not an open ride stake', () {
      final summary = EarningsSummary.from([
        completed('a', fare: 13.2, completedAt: '2026-09-02T10:00:00Z'),
        completed('b', fare: 7.0, completedAt: '2026-09-03T10:00:00Z'),
        // An in-progress ride still carries the booked quote; it has no final
        // charge and must not be paid out.
        Ride(
          id: 'c',
          riderId: 'u1',
          status: 'in_progress',
          totalFare: 99,
          requestedAt: '2026-09-04T10:00:00Z',
        ),
      ], now: now);

      expect(summary.completedTrips, 2);
      expect(summary.monthTrips, 2);
      expect(summary.monthTotal, 20.2);
      expect(summary.loadedTotal, 20.2);
    });

    test('earningsProvider sums whatever history is loaded', () async {
      when(() => repo.history(page: 1, perPage: historyPageSize)).thenAnswer(
        (_) async => page([
          completed('a', fare: 10, completedAt: '2026-09-02T10:00:00Z'),
          completed('b', fare: 5, completedAt: '2026-09-03T10:00:00Z'),
        ], total: 2),
      );

      expect(container.read(earningsProvider), same(EarningsSummary.empty));

      await history().refresh();

      final summary = container.read(earningsProvider);
      expect(summary.loadedTotal, 15);
      expect(summary.completedTrips, 2);
    });
  });
}
