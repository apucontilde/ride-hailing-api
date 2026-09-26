import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:driver_app/features/rides/data/rides_repository.dart';
import 'package:driver_app/features/rides/presentation/rate_sheet.dart';

class MockRidesRepository extends Mock implements RidesRepository {}

void main() {
  late MockRidesRepository repo;

  setUp(() {
    repo = MockRidesRepository();
  });

  Future<void> pumpSheet(
    WidgetTester tester, {
    required String rideId,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [ridesRepositoryProvider.overrideWith((ref) => repo)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => RateSheet(rideId: rideId),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  bool submitEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byKey(const Key('rate-submit'))).onPressed !=
      null;

  testWidgets('submit stays disabled until a star is picked', (tester) async {
    await pumpSheet(tester, rideId: 'r1');

    expect(find.text('Rate your rider'), findsOneWidget);
    expect(find.byKey(const Key('rate-star-1')), findsOneWidget);
    expect(find.byKey(const Key('rate-star-5')), findsOneWidget);
    expect(submitEnabled(tester), isFalse);

    await tester.tap(find.byKey(const Key('rate-star-4')));
    await tester.pump();

    expect(submitEnabled(tester), isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a tapped star fills up to that star', (tester) async {
    await pumpSheet(tester, rideId: 'r1');

    await tester.tap(find.byKey(const Key('rate-star-3')));
    await tester.pump();

    expect(
      tester.widget<Icon>(find.descendant(
        of: find.byKey(const Key('rate-star-1')),
        matching: find.byType(Icon),
      )).icon,
      Icons.star,
    );
    expect(
      tester.widget<Icon>(find.descendant(
        of: find.byKey(const Key('rate-star-4')),
        matching: find.byType(Icon),
      )).icon,
      Icons.star_border,
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('submitting sends score and comment once, then closes',
      (tester) async {
    when(() => repo.rateRide(
          rideId: 'r1',
          score: 5,
          comment: any(named: 'comment'),
        )).thenAnswer((_) async {});

    await pumpSheet(tester, rideId: 'r1');
    await tester.tap(find.byKey(const Key('rate-star-5')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('rate-comment')),
      'Excellent passenger',
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final captured = verify(() => repo.rateRide(
          rideId: captureAny(named: 'rideId'),
          score: captureAny(named: 'score'),
          comment: captureAny(named: 'comment'),
        )).captured;
    expect(captured, ['r1', 5, 'Excellent passenger']);
    expect(find.byType(RateSheet), findsNothing);
    expect(find.text('Thanks — rating sent'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a second submit while one is in flight is impossible',
      (tester) async {
    final gate = Completer<void>();
    when(() => repo.rateRide(
          rideId: 'r1',
          score: 4,
          comment: any(named: 'comment'),
        )).thenAnswer((_) => gate.future);

    await pumpSheet(tester, rideId: 'r1');
    await tester.tap(find.byKey(const Key('rate-star-4')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();
    expect(submitEnabled(tester), isFalse);

    // The control is disabled, so the taps below are inert.
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();

    verify(() => repo.rateRide(
          rideId: 'r1',
          score: 4,
          comment: any(named: 'comment'),
        )).called(1);

    gate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(RateSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a failure shows an inline error and keeps the sheet open',
      (tester) async {
    when(() => repo.rateRide(
          rideId: 'r1',
          score: 1,
          comment: any(named: 'comment'),
        )).thenThrow(Exception('500'));

    await pumpSheet(tester, rideId: 'r1');
    await tester.tap(find.byKey(const Key('rate-star-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('rate-error')), findsOneWidget);
    expect(
      find.text('Could not send your rating. Please try again.'),
      findsOneWidget,
    );
    // The sheet stays up so the driver can retry — a silently dropped rating
    // is data loss, since the server gives them no way to see it did not land.
    expect(find.byType(RateSheet), findsOneWidget);
    expect(submitEnabled(tester), isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a rejected score is reported without closing', (tester) async {
    when(() => repo.rateRide(
          rideId: 'r1',
          score: 2,
          comment: any(named: 'comment'),
        )).thenThrow(ArgumentError('score must be between 1 and 5'));

    await pumpSheet(tester, rideId: 'r1');
    await tester.tap(find.byKey(const Key('rate-star-2')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Pick between 1 and 5 stars.'), findsOneWidget);
    expect(find.byType(RateSheet), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"Not now" closes without rating', (tester) async {
    await pumpSheet(tester, rideId: 'r1');
    await tester.tap(find.byKey(const Key('rate-star-5')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('rate-skip')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verifyNever(() => repo.rateRide(
          rideId: any(named: 'rideId'),
          score: any(named: 'score'),
          comment: any(named: 'comment'),
        ));
    expect(find.byType(RateSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });

  group('ratedRideIdsProvider', () {
    testWidgets('a successful submit marks the ride rated', (tester) async {
      when(() => repo.rateRide(
            rideId: 'r1',
            score: 5,
            comment: any(named: 'comment'),
          )).thenAnswer((_) async {});

      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [ridesRepositoryProvider.overrideWith((ref) => repo)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    capturedRef = ref;
                    return Center(
                      child: TextButton(
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => const RateSheet(rideId: 'r1'),
                        ),
                        child: const Text('open'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(isRated(capturedRef, 'r1'), isFalse);

      await tester.tap(find.byKey(const Key('rate-star-5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('rate-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(isRated(capturedRef, 'r1'), isTrue);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a failed submit leaves the ride unrated', (tester) async {
      when(() => repo.rateRide(
            rideId: 'r1',
            score: 5,
            comment: any(named: 'comment'),
          )).thenThrow(Exception('500'));

      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [ridesRepositoryProvider.overrideWith((ref) => repo)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    capturedRef = ref;
                    return Center(
                      child: TextButton(
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          builder: (_) => const RateSheet(rideId: 'r1'),
                        ),
                        child: const Text('open'),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      await tester.tap(find.byKey(const Key('rate-star-5')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('rate-submit')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(isRated(capturedRef, 'r1'), isFalse);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('markRated is idempotent', (tester) async {
      late WidgetRef capturedRef;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                capturedRef = ref;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      markRated(capturedRef, 'r1');
      markRated(capturedRef, 'r1');
      markRated(capturedRef, 'r2');

      expect(capturedRef.read(ratedRideIdsProvider), {'r1', 'r2'});

      await tester.pumpWidget(const SizedBox());
    });
  });
}
