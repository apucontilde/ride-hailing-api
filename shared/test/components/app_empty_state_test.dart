import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('AppEmptyState renders icon, message and action', (tester) async {
    await tester.pumpWidget(
      wrap(AppEmptyState(
        icon: Icons.history,
        message: 'No rides yet',
        action: TextButton(onPressed: () {}, child: const Text('Retry')),
        topSpacing: 0,
      )),
    );

    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.text('No rides yet'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('AppErrorState renders the error message and retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      wrap(AppErrorState(
        message: 'history query failed',
        onRetry: () => retries++,
        topSpacing: 0,
      )),
    );

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.text('history query failed'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
  });

  testWidgets('AppErrorRow renders inline message and optional retry',
      (tester) async {
    var retried = false;
    await tester.pumpWidget(
      wrap(AppErrorRow(
        message: 'failed to calculate route',
        onRetry: () => retried = true,
      )),
    );

    expect(find.text('failed to calculate route'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('AppErrorRow without a retry has no Retry text', (tester) async {
    await tester.pumpWidget(wrap(const AppErrorRow(message: 'boom')));
    expect(find.text('Retry'), findsNothing);
  });
}
