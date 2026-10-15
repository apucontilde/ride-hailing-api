import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/core/location/app_lifecycle_notifier.dart';

void main() {
  group('AppLifecycleNotifier', () {
    test('starts in resumed', () {
      final notifier = AppLifecycleNotifier();
      addTearDown(notifier.dispose);
      expect(notifier.state, AppLifecycleState.resumed);
    });

    test('fires onResumed only on a transition into resumed', () {
      final notifier = AppLifecycleNotifier();
      addTearDown(notifier.dispose);
      var resumedCount = 0;
      notifier.onResumed = () => resumedCount++;

      notifier.update(AppLifecycleState.inactive);
      notifier.update(AppLifecycleState.paused);
      // Background states never fire the resume hook.
      expect(resumedCount, 0);

      notifier.update(AppLifecycleState.resumed);
      expect(resumedCount, 1);
      expect(notifier.state, AppLifecycleState.resumed);

      // A duplicate resumed event must not re-fire (the observer can repeat it).
      notifier.update(AppLifecycleState.resumed);
      expect(resumedCount, 1);

      // A second genuine background→foreground cycle fires again.
      notifier.update(AppLifecycleState.paused);
      notifier.update(AppLifecycleState.resumed);
      expect(resumedCount, 2);
    });

    test('the provider exposes a notifier whose state follows updates', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(appLifecycleProvider.notifier);
      expect(container.read(appLifecycleProvider), AppLifecycleState.resumed);

      notifier.update(AppLifecycleState.paused);
      expect(container.read(appLifecycleProvider), AppLifecycleState.paused);
    });
  });
}
