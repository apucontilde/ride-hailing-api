import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared harness for the driver's modal bottom sheets (`OfferSheet`,
/// `RateSheet`): pumps a `ProviderScope` whose only UI is an "open" button that
/// shows [builder] as a scroll-controlled modal sheet, then opens it and
/// settles the entrance animation.
Future<void> pumpModalSheet(
  WidgetTester tester, {
  required List<Override> overrides,
  required WidgetBuilder builder,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: builder,
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

/// Unmounts the sheet so any pending timer (the offer countdown, SnackBars) is
/// cancelled before the test ends, instead of each suite repeating a bare
/// `pumpWidget(const SizedBox())`.
Future<void> drainModalTimers(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());