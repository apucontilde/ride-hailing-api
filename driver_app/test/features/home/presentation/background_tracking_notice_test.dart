import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/features/home/presentation/background_tracking_notice.dart';

void main() {
  Future<void> pumpNotice(
    WidgetTester tester, {
    required Future<bool> Function() openSettings,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [openAppSettingsProvider.overrideWithValue(openSettings)],
        child: const MaterialApp(
          home: Scaffold(body: BackgroundTrackingNotice()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('explains background tracking and offers the settings deep-link',
      (tester) async {
    var opened = 0;
    await pumpNotice(tester, openSettings: () async {
      opened++;
      return true;
    });

    expect(find.byKey(const Key('background-tracking-notice')), findsOneWidget);
    final content = tester.widget<Text>(
      find.textContaining('switch apps or lock the screen'),
    );
    expect(content.data, contains('Allow all the time'));

    await tester.tap(find.byKey(const Key('background-tracking-open-settings')));
    await tester.pumpAndSettle();
    expect(opened, 1, reason: 'Open settings must invoke the deep-link');
  });

  testWidgets('Got it dismisses without opening settings', (tester) async {
    var opened = 0;
    await pumpNotice(tester, openSettings: () async {
      opened++;
      return true;
    });

    await tester.tap(find.byKey(const Key('background-tracking-dismiss')));
    await tester.pumpAndSettle();
    expect(opened, 0);
  });
}
