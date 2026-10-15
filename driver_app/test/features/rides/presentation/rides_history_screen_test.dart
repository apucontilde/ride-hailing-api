import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/features/payout/data/payout_repository.dart';
import 'package:driver_app/features/payout/model/driver_earnings.dart';
import 'package:driver_app/features/payout/providers/payout_providers.dart';
import 'package:driver_app/features/rides/data/rides_repository.dart';
import 'package:driver_app/features/rides/presentation/rate_sheet.dart';
import 'package:driver_app/features/rides/data/rated_rides_provider.dart';
import 'package:driver_app/features/rides/presentation/rides_history_screen.dart';
import 'package:driver_app/features/rides/providers/history_provider.dart';

class MockRidesRepository extends Mock implements RidesRepository {}

class MockPayoutRepository extends Mock implements PayoutRepository {}

/// The earnings card compares against the *real* current month, so the fixtures
/// are anchored to "now" rather than to a hard-coded date that would quietly
/// start failing next month.
final _now = DateTime.now();

/// Noon on the 1st of the current month, as RFC 3339.
String get _thisMonth =>
    DateTime(_now.year, _now.month, 1, 12).toIso8601String();

/// Noon on the 1st of the previous month (`DateTime` normalises month 0).
String get _lastMonth =>
    DateTime(_now.year, _now.month - 1, 1, 12).toIso8601String();

/// Hardcoded month names, deliberately independent of the production
/// `EarningsMonth.label` formatter: if that formatter ever changed shape this
/// test should go red rather than silently agree with it.
const _monthNames = [
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

String _monthLabel(int year, int month) => '${_monthNames[month - 1]} $year';

/// The literal label the card must show for [_thisMonth].
String get _thisMonthLabel => _monthLabel(_now.year, _now.month);

String get _lastMonthLabel => _monthLabel(_now.year, _now.month - 1);

Ride ride(
  String id, {
  required String status,
  double? fare,
  String? currency,
  String? completedAt,
  String? cancelledBy,
}) {
  return Ride(
    id: id,
    riderId: 'u1',
    status: status,
    pickupAddress: 'Pick $id',
    dropoffAddress: 'Drop $id',
    totalFare: fare,
    fareCurrency: currency,
    completedAt: completedAt,
    cancelledBy: cancelledBy,
    requestedAt: '2020-01-05T08:00:00Z',
  );
}

RideHistoryPage page(List<Ride> rides, {int total = 0, int pageNumber = 1}) {
  return RideHistoryPage(
    rides: rides,
    total: total,
    page: pageNumber,
    perPage: historyPageSize,
    totalPages: (total / historyPageSize).ceil(),
  );
}

/// One page of `GET /driver/ratings`: the driver rated exactly [rideIds].
/// `total_pages: 1`, so the provider stops after this request.
DriverRatingPage ratingsPage(List<String> rideIds) {
  return DriverRatingPage(
    ratings: [
      for (final id in rideIds)
        DriverRating(
          id: 'rating-$id',
          rideId: id,
          raterRole: 'driver',
          score: 5,
          comment: null,
          createdAt: _now,
        ),
    ],
    total: rideIds.length,
    page: 1,
    perPage: ratedRidesPageSize,
    totalPages: 1,
  );
}

/// A server earnings summary for the card. Defaults are the honest empty
/// ledger: zero everywhere and no currency (so amounts render bare rather than
/// a fabricated `$`).
DriverEarningsSummary earningsSummary({
  int availableCents = 0,
  int pendingCents = 0,
  int withdrawnCents = 0,
  int lifetimeCents = 0,
  String? currency,
  int monthTotalCents = 0,
  int monthTrips = 0,
  int completedTrips = 0,
  List<DriverEarningsMonth> months = const [],
}) {
  return DriverEarningsSummary(
    availableCents: availableCents,
    pendingCents: pendingCents,
    withdrawnCents: withdrawnCents,
    lifetimeCents: lifetimeCents,
    currency: currency,
    monthTotalCents: monthTotalCents,
    monthTrips: monthTrips,
    completedTrips: completedTrips,
    months: months,
  );
}

void main() {
  late MockRidesRepository repo;
  late MockPayoutRepository payout;

  /// [rides] become page 1; [next] becomes page 2.
  void stubHistory(List<Ride> rides, {List<Ride>? next, int total = 0}) {
    when(
      () => repo.history(page: 1, perPage: historyPageSize),
    ).thenAnswer((_) async => page(rides, total: total));
    if (next != null) {
      when(
        () => repo.history(page: 2, perPage: historyPageSize),
      ).thenAnswer((_) async => page(next, total: total, pageNumber: 2));
    }
  }

  /// Stubs the server's list of rides the driver has already rated. Defaults to
  /// "rated nothing", which is the only state in which a prompt may appear, so
  /// every unrelated case keeps a prompt on screen.
  void stubRatings(List<String> rideIds) {
    when(
      () => repo.fetchMyRatings(
        page: 1,
        perPage: ratedRidesPageSize,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => ratingsPage(rideIds));
  }

  /// Holds the ratings request open, so the in-flight window is observable.
  Completer<DriverRatingPage> gateRatings() {
    final gate = Completer<DriverRatingPage>();
    when(
      () => repo.fetchMyRatings(
        page: 1,
        perPage: ratedRidesPageSize,
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) => gate.future);
    return gate;
  }

  /// Stubs the ledger the earnings card reads. Defaults to the empty summary.
  void stubEarnings(DriverEarningsSummary summary) {
    when(() => payout.fetchEarnings()).thenAnswer((_) async => summary);
  }

  /// Holds the earnings request open, so the in-flight window is observable.
  Completer<DriverEarningsSummary> gateEarnings() {
    final gate = Completer<DriverEarningsSummary>();
    when(() => payout.fetchEarnings()).thenAnswer((_) => gate.future);
    return gate;
  }

  setUp(() {
    repo = MockRidesRepository();
    payout = MockPayoutRepository();
    stubEarnings(earningsSummary());
    // The prompt is server-gated: without this the list is `unknown` and no
    // tile offers a rating, which would silently change every case below.
    stubRatings(const []);
  });

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ridesRepositoryProvider.overrideWith((ref) => repo),
          payoutRepositoryProvider.overrideWith((ref) => payout),
        ],
        // Body-only since bug #10; host it in a Scaffold the way DriverShell
        // does in the app.
        child: const MaterialApp(home: Scaffold(body: RidesHistoryScreen())),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an empty history says so instead of showing a bare list', (
    tester,
  ) async {
    stubHistory(const []);

    await pumpHistory(tester);

    expect(find.text('No trips yet'), findsOneWidget);
    expect(find.byType(AppEmptyState), findsOneWidget);
    // The design migration dropped this helper sentence when the per-screen
    // `_EmptyState` became the shared `AppEmptyState`; it must stay.
    expect(
      find.text('Completed trips and your fares will show up here.'),
      findsOneWidget,
    );
    // The empty ledger renders bare amounts (no fabricated `$`); assert via the
    // card keys, since both the balance and the month total are `0.00`.
    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-available'))).data,
      '0.00',
    );
    expect(find.text('0 completed trips'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a pull-down on the empty state re-fetches the history', (
    tester,
  ) async {
    stubHistory(const []);

    await pumpHistory(tester);
    expect(find.byType(AppEmptyState), findsOneWidget);

    // Drag down on the empty surface itself. In the nested build this started a
    // scroll inside the `AppEmptyState` `ListView`, so the inner scrollable
    // consumed it at notification depth 1 and the enclosing `RefreshIndicator`
    // never fired; now the empty state is the `RefreshIndicator`'s own
    // scrollable, so the pull reaches it and `refreshAll` runs.
    await tester.fling(find.text('No trips yet'), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1)); // scroll animation
    await tester.pump(const Duration(seconds: 1)); // indicator settle
    await tester.pump(const Duration(seconds: 1)); // indicator hide

    // One load from `initState` plus one from the pull. `verify` consumes the
    // calls it matches, so this is asserted once, at the end.
    verify(() => repo.history(page: 1, perPage: historyPageSize)).called(2);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the earnings card renders the server ledger figures', (
    tester,
  ) async {
    stubHistory([
      ride('r1', status: 'completed', fare: 10, currency: 'USD', completedAt: _thisMonth),
    ], total: 1);
    stubEarnings(
      earningsSummary(
        availableCents: 2000,
        pendingCents: 500,
        withdrawnCents: 1000,
        lifetimeCents: 2500,
        currency: 'USD',
        monthTotalCents: 2550,
        monthTrips: 2,
        completedTrips: 5,
      ),
    );

    await pumpHistory(tester);

    // The card is the server's ledger — integer cents converted exactly once,
    // never a sum over the rides loaded below it.
    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-available'))).data,
      'USD20.00',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-month-total'))).data,
      'USD25.50',
    );
    expect(find.text('2 completed trips'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-pending'))).data,
      'USD5.00',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-withdrawn'))).data,
      'USD10.00',
    );
    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-lifetime'))).data,
      'USD25.00',
    );
    // A positive balance offers the withdraw affordance.
    expect(find.byKey(const Key('withdraw-button')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the card shows a spinner, not a fabricated 0.00, while loading', (
    tester,
  ) async {
    stubHistory(const []);
    final gate = gateEarnings();

    await pumpHistory(tester);

    // Nothing invented while the ledger is unknown.
    expect(find.byKey(const Key('earnings-available')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(AppCard),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    gate.complete(earningsSummary(availableCents: 1500, currency: 'USD'));
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-available'))).data,
      'USD15.00',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failed ledger shows a retry and recovers', (tester) async {
    stubHistory(const []);
    when(() => payout.fetchEarnings()).thenThrow(Exception('boom'));

    await pumpHistory(tester);

    expect(find.byKey(const Key('earnings-error')), findsOneWidget);
    expect(find.text(earningsErrorMessage), findsOneWidget);
    expect(find.byKey(const Key('earnings-available')), findsNothing);

    stubEarnings(earningsSummary(availableCents: 700, currency: 'USD'));
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('earnings-error')),
        matching: find.byType(TextButton),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-available'))).data,
      'USD7.00',
    );
    expect(find.byKey(const Key('earnings-error')), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a completed tile renders the final fare at cents with its currency',
    (tester) async {
      stubHistory([
        ride(
          'r1',
          status: 'completed',
          fare: 13.2,
          currency: 'USD',
          completedAt: _thisMonth,
        ),
      ], total: 1);

      await pumpHistory(tester);

      // The final charge from the API, at two decimals and prefixed with the
      // API's own currency code — never a rounded or invented value. Scoped to
      // the tile: the ledger card above it is the server's, not this sum.
      expect(
        find.descendant(
          of: find.byKey(const Key('ride-tile-r1')),
          matching: find.text('USD13.20'),
        ),
        findsOneWidget,
      );
      expect(find.text('USD13.00'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a month breakdown lists the ledger months newest first', (
    tester,
  ) async {
    stubHistory(const []);
    stubEarnings(
      earningsSummary(
        currency: 'USD',
        monthTotalCents: 1700,
        monthTrips: 2,
        months: [
          DriverEarningsMonth(
            month: DateTime(_now.year, _now.month),
            totalCents: 1000,
            trips: 1,
          ),
          DriverEarningsMonth(
            month: DateTime(_now.year, _now.month - 1),
            totalCents: 700,
            trips: 1,
          ),
        ],
      ),
    );

    await pumpHistory(tester);

    expect(find.text(_thisMonthLabel), findsOneWidget);
    expect(find.text('1 · USD10.00'), findsOneWidget);
    expect(find.text(_lastMonthLabel), findsOneWidget);
    expect(find.text('1 · USD7.00'), findsOneWidget);
    // The withdraw affordance is live now that the endpoint is real, and the
    // caveat still says the money is only a pending ledger entry.
    expect(find.byKey(const Key('withdraw-button')), findsOneWidget);
    expect(find.textContaining('pending ledger'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the ledger renders a non-USD region code, never \$', (
    tester,
  ) async {
    stubHistory(const []);
    stubEarnings(earningsSummary(currency: 'CRC', monthTotalCents: 800));

    await pumpHistory(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-month-total'))).data,
      'CRC8.00',
    );
    expect(find.text(r'$8.00'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a summary with no currency renders bare, never a guessed \$', (
    tester,
  ) async {
    stubHistory(const []);
    stubEarnings(earningsSummary(currency: null, monthTotalCents: 1000));

    await pumpHistory(tester);

    expect(
      tester.widget<Text>(find.byKey(const Key('earnings-month-total'))).data,
      '10.00',
    );
    expect(find.text('USD10.00'), findsNothing);
    expect(find.text(r'$10.00'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('only completed rides offer a rating, and only once', (
    tester,
  ) async {
    stubHistory([
      ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
      ride('r2', status: 'cancelled', fare: 5, cancelledBy: 'driver'),
    ], total: 2);

    await pumpHistory(tester);

    expect(find.byKey(const Key('rate-button-r1')), findsOneWidget);
    expect(find.byKey(const Key('rate-button-r2')), findsNothing);

    // What a successful submit does: the server now lists r1 as rated.
    stubRatings(['r1']);
    await tester.tap(find.byKey(const Key('history-refresh')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('rate-button-r1')), findsNothing);
    expect(find.text('Rated'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  group('the prompt follows the server list', () {
    testWidgets('nothing is offered while the rated list is still loading', (
      tester,
    ) async {
      final gate = gateRatings();
      stubHistory([
        ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
      ], total: 1);

      await pumpHistory(tester);

      // Unknown, not unrated: a completed ride must not be offered back to a
      // driver who may well have rated it on a previous session.
      expect(find.byKey(const Key('rate-button-r1')), findsNothing);
      expect(find.text('Rated'), findsNothing);

      gate.complete(ratingsPage(const []));
      await tester.pump();
      await tester.pump();

      // Loaded and absent: now the prompt is honest and appears.
      expect(find.byKey(const Key('rate-button-r1')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a ride the server lists as rated offers nothing', (
      tester,
    ) async {
      stubRatings(['r1']);
      stubHistory([
        ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
        ride('r2', status: 'completed', fare: 4, completedAt: _thisMonth),
      ], total: 2);

      await pumpHistory(tester);

      expect(find.byKey(const Key('rate-button-r1')), findsNothing);
      expect(find.byKey(const Key('rate-button-r2')), findsOneWidget);
      expect(find.text('Rated'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed list offers nothing and retries on demand', (
      tester,
    ) async {
      when(
        () => repo.fetchMyRatings(
          page: 1,
          perPage: ratedRidesPageSize,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenThrow(Exception('boom'));
      stubHistory([
        ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
      ], total: 1);

      await pumpHistory(tester);

      // The trip list is fine; only the rated list failed.
      expect(find.byKey(const Key('ride-tile-r1')), findsOneWidget);
      expect(find.byKey(const Key('rate-button-r1')), findsNothing);
      expect(find.text(ratedRidesErrorMessage), findsOneWidget);

      // Retry re-requests, and the prompt returns once the server answers.
      stubRatings(const []);
      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('error-retry')).last,
          matching: find.byType(TextButton),
        ),
      );
      await tester.pump();
      await tester.pump();

      verify(
        () => repo.fetchMyRatings(
          page: 1,
          perPage: ratedRidesPageSize,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).called(2);
      expect(find.text(ratedRidesErrorMessage), findsNothing);
      expect(find.byKey(const Key('rate-button-r1')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the refresh control re-reads the rated list', (tester) async {
      stubHistory([
        ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
      ], total: 1);

      await pumpHistory(tester);
      expect(find.byKey(const Key('rate-button-r1')), findsOneWidget);

      stubRatings(['r1']);
      await tester.tap(find.byKey(const Key('history-refresh')));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('rate-button-r1')), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('the rate button opens the rating sheet for that ride', (
    tester,
  ) async {
    stubHistory([
      ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
    ], total: 1);
    when(
      () => repo.rateRide(
        rideId: 'r1',
        score: 5,
        comment: any(named: 'comment'),
      ),
    ).thenAnswer((_) async {});

    await pumpHistory(tester);
    await tester.tap(find.byKey(const Key('rate-button-r1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.byType(RateSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key('rate-star-5')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(
      () => repo.rateRide(
        rideId: 'r1',
        score: 5,
        comment: any(named: 'comment'),
      ),
    ).called(1);
    // The tile retires its button once rated, so a second prompt is impossible.
    expect(find.byKey(const Key('rate-button-r1')), findsNothing);
    expect(find.text('Rated'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scrolling near the bottom appends the next page', (
    tester,
  ) async {
    stubHistory(
      [
        for (var i = 0; i < historyPageSize; i++)
          ride('r$i', status: 'completed', fare: 1, completedAt: _thisMonth),
      ],
      next: [
        ride('older', status: 'completed', fare: 2, completedAt: _lastMonth),
      ],
      total: 25,
    );

    await pumpHistory(tester);
    expect(find.byKey(const Key('ride-tile-older')), findsNothing);
    expect(find.text('That is every trip.'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();

    verify(() => repo.history(page: 2, perPage: historyPageSize)).called(1);
    final ctx = tester.element(find.byType(RidesHistoryScreen));
    final state = ProviderScope.containerOf(ctx).read(historyProvider);
    expect(state.rides, hasLength(historyPageSize + 1));
    // A short page 2 means the list is complete.
    expect(state.hasMore, isFalse);

    // The appended tile sits past the old scroll extent, and `find` skips what
    // the ListView has not built — so scroll it into view explicitly.
    await tester.scrollUntilVisible(
      find.byKey(const Key('ride-tile-older')),
      200,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.byKey(const Key('ride-tile-older')), findsOneWidget);
    expect(find.text('That is every trip.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a load error keeps the list and offers a retry', (tester) async {
    stubHistory([
      ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
    ], total: 1);
    await pumpHistory(tester);
    expect(find.byKey(const Key('ride-tile-r1')), findsOneWidget);

    when(
      () => repo.history(page: 1, perPage: historyPageSize),
    ).thenThrow(Exception('boom'));
    await tester.tap(find.byKey(const Key('history-refresh')));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not load your ride history.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(AppErrorRow), findsOneWidget);
    expect(find.byKey(const Key('ride-tile-r1')), findsOneWidget);

    // Retry re-requests and the error clears once it succeeds.
    stubHistory([
      ride('r1', status: 'completed', fare: 10, completedAt: _thisMonth),
    ], total: 1);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Could not load your ride history.'), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}
