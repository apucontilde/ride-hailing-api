import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// The shared locate button's state machine, exercised without a real map.
void main() {
  final finder = find.byKey(const Key('map-locate-button'));

  Future<void> pumpButton(
    WidgetTester tester, {
    required Object? routeKey,
    required bool hasRoute,
    required bool Function() onFitRoute,
    required Future<bool> Function() onCurrentLocation,
    VoidCallback? onLocationUnavailable,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppMapLocateButton(
              routeKey: routeKey,
              hasRoute: hasRoute,
              onFitRoute: onFitRoute,
              onCurrentLocation: onCurrentLocation,
              onLocationUnavailable: onLocationUnavailable,
            ),
          ),
        ),
      ),
    );
    // Flush the post-frame auto-fit and its setState.
    await tester.pump();
  }

  testWidgets('auto-fits on mount; the first tap locates', (tester) async {
    var fits = 0;
    var locates = 0;

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: true,
      onFitRoute: () {
        fits++;
        return true;
      },
      onCurrentLocation: () async {
        locates++;
        return true;
      },
    );

    expect(fits, 1, reason: 'the initial mount auto-fits once');
    expect(find.byTooltip('Current location'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();

    expect(locates, 1);
    expect(fits, 1, reason: 'the first tap locates, not fits');
    expect(find.byTooltip('Fit route'), findsOneWidget);
  });

  testWidgets('a successful locate advances back to fit; fit advances to locate', (
    tester,
  ) async {
    var fits = 0;
    var locates = 0;

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: true,
      onFitRoute: () {
        fits++;
        return true;
      },
      onCurrentLocation: () async {
        locates++;
        return true;
      },
    );

    // Auto-fit is the fit half, so tap 1 locates.
    await tester.tap(finder);
    await tester.pump();
    expect(locates, 1);
    expect(find.byTooltip('Fit route'), findsOneWidget);

    // Tap 2 fits.
    await tester.tap(finder);
    await tester.pump();
    expect(fits, 2);
    expect(find.byTooltip('Current location'), findsOneWidget);

    // Tap 3 locates again.
    await tester.tap(finder);
    await tester.pump();
    expect(locates, 2);
    expect(find.byTooltip('Fit route'), findsOneWidget);
  });

  testWidgets('a routeKey change auto-fits again and the next tap locates', (
    tester,
  ) async {
    var fits = 0;
    var locates = 0;

    bool fit() {
      fits++;
      return true;
    }

    Future<bool> locate() async {
      locates++;
      return true;
    }

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: true,
      onFitRoute: fit,
      onCurrentLocation: locate,
    );
    expect(fits, 1);

    // Consume the locate half so the cycle is on fit.
    await tester.tap(finder);
    await tester.pump();
    expect(locates, 1);
    expect(find.byTooltip('Fit route'), findsOneWidget);

    await pumpButton(
      tester,
      routeKey: 'route-b',
      hasRoute: true,
      onFitRoute: fit,
      onCurrentLocation: locate,
    );

    expect(fits, 2, reason: 'a material route change auto-fits');
    expect(find.byTooltip('Current location'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();
    expect(locates, 2);
  });

  testWidgets('a failed auto-fit leaves the next tap on fit', (tester) async {
    var fits = 0;
    var locates = 0;
    var succeed = false;

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: true,
      onFitRoute: () {
        fits++;
        return succeed;
      },
      onCurrentLocation: () async {
        locates++;
        return true;
      },
    );

    expect(fits, 1);
    expect(find.byTooltip('Fit route'), findsOneWidget);

    // The retry succeeds, so the action advances.
    succeed = true;
    await tester.tap(finder);
    await tester.pump();
    expect(fits, 2);
    expect(find.byTooltip('Current location'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();
    expect(locates, 1);
  });

  testWidgets('a failed locate stays on locate, retries and reports each time', (
    tester,
  ) async {
    var locates = 0;
    var unavailable = 0;

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: true,
      onFitRoute: () => true,
      onCurrentLocation: () async {
        locates++;
        return false;
      },
      onLocationUnavailable: () => unavailable++,
    );

    expect(find.byTooltip('Current location'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();
    expect(locates, 1);
    expect(unavailable, 1);
    expect(find.byTooltip('Current location'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();
    expect(locates, 2);
    expect(unavailable, 2);
    expect(find.byTooltip('Current location'), findsOneWidget);
  });

  testWidgets('hasRoute false never auto-fits and every tap locates', (
    tester,
  ) async {
    var fits = 0;
    var locates = 0;

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: false,
      onFitRoute: () {
        fits++;
        return true;
      },
      onCurrentLocation: () async {
        locates++;
        return true;
      },
    );

    expect(fits, 0);
    expect(find.byTooltip('Current location'), findsOneWidget);

    await tester.tap(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();

    expect(locates, 2);
    expect(fits, 0);
  });

  testWidgets('an unresolved locate is not stacked by a second tap', (
    tester,
  ) async {
    var locates = 0;
    final pending = Completer<bool>();

    await pumpButton(
      tester,
      routeKey: 'route-a',
      hasRoute: false,
      onFitRoute: () => true,
      onCurrentLocation: () {
        locates++;
        return pending.future;
      },
    );

    await tester.tap(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();

    expect(locates, 1);

    pending.complete(true);
    await tester.pump();
  });

  testWidgets('renders the shared icon and colours', (tester) async {
    await pumpButton(
      tester,
      routeKey: null,
      hasRoute: false,
      onFitRoute: () => true,
      onCurrentLocation: () async => true,
    );

    final fab = tester.widget<FloatingActionButton>(finder);
    expect(fab.backgroundColor, AppColors.surface);
    final icon = tester.widget<Icon>(
      find.descendant(of: finder, matching: find.byIcon(Icons.my_location)),
    );
    expect(icon.color, AppColors.info);
  });
}
