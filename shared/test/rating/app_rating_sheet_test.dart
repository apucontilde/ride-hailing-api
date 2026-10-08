import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  bool submitEnabled(WidgetTester tester) =>
      tester
          .widget<ElevatedButton>(
            find.descendant(
              of: find.byKey(const Key('rate-submit')),
              matching: find.byType(ElevatedButton),
            ),
          )
          .onPressed !=
      null;

  IconData iconOf(WidgetTester tester, String key) => tester
      .widget<Icon>(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(Icon),
        ),
      )
      .icon!;

  Color colorOf(WidgetTester tester, String key) => tester
      .widget<Icon>(
        find.descendant(
          of: find.byKey(ValueKey<String>(key)),
          matching: find.byType(Icon),
        ),
      )
      .color!;

  testWidgets('selecting a star fills up to it and enables submit', (
    tester,
  ) async {
    final submitted = <int>[];
    await tester.pumpWidget(
      wrap(
        AppRatingSheet(
          title: 'Rate your ride',
          allowComment: true,
          onSubmit: (score, comment) => submitted.add(score),
        ),
      ),
    );

    expect(find.text('Rate your ride'), findsOneWidget);
    expect(find.byKey(const Key('rate-comment')), findsOneWidget);
    // Nothing picked: not submittable.
    expect(submitEnabled(tester), isFalse);

    await tester.tap(find.byKey(const ValueKey<String>('rating-star-3')));
    await tester.pump();

    expect(iconOf(tester, 'rating-star-1'), Icons.star);
    expect(iconOf(tester, 'rating-star-3'), Icons.star);
    expect(iconOf(tester, 'rating-star-4'), Icons.star_border);
    expect(submitEnabled(tester), isTrue);

    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();
    expect(submitted, [3]);
  });

  testWidgets('the driver alias key wraps the same star icon', (tester) async {
    await tester.pumpWidget(
      wrap(AppRatingSheet(title: 'Rate your rider', onSubmit: (_, _) {})),
    );

    expect(find.byKey(const Key('rate-star-1')), findsOneWidget);
    expect(find.byKey(const Key('rate-star-5')), findsOneWidget);
    expect(iconOf(tester, 'rate-star-1'), Icons.star_border);
  });

  testWidgets('star colors are grey unselected and amber selected', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(AppRatingSheet(title: 'Rate', initialScore: 2, onSubmit: (_, _) {})),
    );

    expect(iconOf(tester, 'rating-star-2'), Icons.star);
    expect(iconOf(tester, 'rating-star-3'), Icons.star_border);
    expect(colorOf(tester, 'rating-star-2'), AppColors.warning);
    expect(colorOf(tester, 'rating-star-3'), AppColors.muted);
  });

  testWidgets('busy disables submit and the star taps', (tester) async {
    var submitted = 0;
    await tester.pumpWidget(
      wrap(
        AppRatingSheet(
          title: 'Rate',
          busy: true,
          initialScore: 4,
          onSubmit: (_, _) => submitted++,
        ),
      ),
    );

    expect(submitEnabled(tester), isFalse);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('rating-star-5')),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(submitEnabled(tester), isFalse);
    expect(submitted, 0);
  });

  testWidgets('captures the optional comment when allowed', (tester) async {
    String? captured;
    await tester.pumpWidget(
      wrap(
        AppRatingSheet(
          title: 'Rate',
          allowComment: true,
          onSubmit: (score, comment) => captured = comment,
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('rating-star-5')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('rate-comment')), 'Great ride');
    await tester.tap(find.byKey(const Key('rate-submit')));
    await tester.pump();

    expect(captured, 'Great ride');
  });

  testWidgets('hides the comment field when not allowed', (tester) async {
    await tester.pumpWidget(
      wrap(AppRatingSheet(title: 'Rate', onSubmit: (_, _) {})),
    );

    expect(find.byKey(const Key('rate-comment')), findsNothing);
  });

  testWidgets('renders the inline error', (tester) async {
    await tester.pumpWidget(
      wrap(
        AppRatingSheet(
          title: 'Rate',
          errorText: 'Could not send your rating. Please try again.',
          onSubmit: (_, _) {},
        ),
      ),
    );

    expect(find.byKey(const Key('rate-error')), findsOneWidget);
    expect(
      find.text('Could not send your rating. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets('skip invokes onSkip without submitting', (tester) async {
    var skipped = 0;
    var submitted = 0;
    await tester.pumpWidget(
      wrap(
        AppRatingSheet(
          title: 'Rate',
          onSkip: () => skipped++,
          onSubmit: (_, _) => submitted++,
        ),
      ),
    );

    expect(find.text('Not now'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rate-skip')));
    await tester.pump();

    expect(skipped, 1);
    expect(submitted, 0);
  });

  testWidgets('every score 1..5 is submittable and none below 1 is', (
    tester,
  ) async {
    final submitted = <int>[];
    await tester.pumpWidget(
      wrap(
        AppRatingSheet(
          title: 'Rate',
          onSubmit: (score, _) => submitted.add(score),
        ),
      ),
    );

    expect(submitEnabled(tester), isFalse);
    for (var score = 1; score <= 5; score++) {
      await tester.tap(find.byKey(ValueKey<String>('rating-star-$score')));
      await tester.pump();
      expect(submitEnabled(tester), isTrue);
      await tester.tap(find.byKey(const Key('rate-submit')));
      await tester.pump();
    }

    expect(submitted, [1, 2, 3, 4, 5]);
  });
}
