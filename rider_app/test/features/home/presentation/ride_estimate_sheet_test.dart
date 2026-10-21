import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/presentation/ride_estimate_sheet.dart';
import 'package:rider_app/features/home/model/ride_estimate.dart';

Widget _sheet(List<RideEstimate> estimates) => MaterialApp(
  home: Scaffold(
    body: RideEstimateSheet(
      estimates: estimates,
      pickupLat: 0,
      pickupLng: 0,
      dropoffLat: 0,
      dropoffLng: 0,
    ),
  ),
);

/// Opens the sheet through the production `showModalBottomSheet` path at a
/// short/viewport-limited surface.
Future<void> _pumpModal(
  WidgetTester tester,
  List<RideEstimate> estimates, {
  Size surface = const Size(400, 480),
}) async {
  tester.view.physicalSize = surface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showModalBottomSheet<String>(
                context: context,
                isScrollControlled: true,
                builder: (_) => RideEstimateSheet(
                  estimates: estimates,
                  pickupLat: 0,
                  pickupLng: 0,
                  dropoffLat: 0,
                  dropoffLng: 0,
                ),
              ),
              child: const Text('Open sheet'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open sheet'));
  await tester.pumpAndSettle();
}

const _fourEstimates = [
  RideEstimate(
    vehicleType: 'sedan',
    baseFare: 2.50,
    distanceFare: 3.10,
    timeFare: 0.90,
    total: 6.50,
    currency: '\$',
  ),
  RideEstimate(
    vehicleType: 'suv',
    baseFare: 3.50,
    distanceFare: 4.00,
    timeFare: 1.00,
    total: 8.50,
    currency: '\$',
  ),
  RideEstimate(
    vehicleType: 'premium',
    baseFare: 5.00,
    distanceFare: 6.00,
    timeFare: 1.50,
    total: 12.50,
    currency: '\$',
  ),
  RideEstimate(
    vehicleType: 'van',
    baseFare: 6.00,
    distanceFare: 7.00,
    timeFare: 2.00,
    total: 15.00,
    currency: '\$',
  ),
];

void main() {
  testWidgets(
    'shows vehicle options and the computed total as the option price',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _sheet([
          const RideEstimate(
            vehicleType: 'sedan',
            baseFare: 2.50,
            distanceFare: 3.10,
            timeFare: 0.90,
            total: 6.50,
            currency: '\$',
            etaSeconds: 300,
          ),
          const RideEstimate(
            vehicleType: 'suv',
            baseFare: 3.50,
            distanceFare: 4.00,
            timeFare: 1.00,
            total: 8.50,
            currency: '\$',
            etaSeconds: 420,
          ),
        ]),
      );

      expect(find.text('Sedan'), findsOneWidget);
      expect(find.text('SUV'), findsOneWidget);
      expect(find.text('\$8.50'), findsOneWidget);
      expect(find.text('\$6.50'), findsNWidgets(2));
      expect(find.text('\$2.50'), findsOneWidget);
    },
  );

  testWidgets('renders the API breakdown lines for the selected estimate', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([
        const RideEstimate(
          vehicleType: 'sedan',
          baseFare: 2.50,
          distanceFare: 3.10,
          timeFare: 0.90,
          surgeMultiplier: 1.20,
          total: 6.50,
          currency: '\$',
        ),
      ]),
    );

    expect(find.text('Base fare'), findsOneWidget);
    expect(find.text('Distance fare'), findsOneWidget);
    expect(find.text('Time fare'), findsOneWidget);
    expect(find.text('Conditions multiplier'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('\$3.10'), findsOneWidget);
    expect(find.text('×1.20'), findsOneWidget);
  });

  testWidgets('renders the API currency when sent', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([
        const RideEstimate(
          vehicleType: 'sedan',
          baseFare: 2.50,
          total: 6.50,
          currency: 'USD',
        ),
      ]),
    );

    expect(find.text('USD6.50'), findsNWidgets(2));
    expect(find.text('USD2.50'), findsOneWidget);
  });

  testWidgets('omits currency when the API did not send one', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([
        const RideEstimate(vehicleType: 'sedan', baseFare: 2.50, total: 6.50),
      ]),
    );

    expect(find.text('6.50'), findsNWidgets(2));
    expect(find.textContaining('USD'), findsNothing);
  });

  testWidgets('a zero or absent grade uplift adds no line', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([const RideEstimate(vehicleType: 'sedan', total: 6.50)]),
    );

    expect(find.textContaining('climb'), findsNothing);
  });

  testWidgets('a non-zero grade uplift annotates the distance leg', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([
        const RideEstimate(
          vehicleType: 'sedan',
          distanceFare: 3.10,
          total: 6.50,
          gradeUpliftPct: 0.05,
        ),
      ]),
    );

    expect(find.text('climb +5.0%'), findsOneWidget);
  });

  testWidgets('confirming pops with the selected vehicle type', (
    WidgetTester tester,
  ) async {
    String? popped;
    const sedan = RideEstimate(
      vehicleType: 'sedan',
      baseFare: 10.00,
      total: 10.00,
    );
    const suv = RideEstimate(vehicleType: 'suv', baseFare: 12.00, total: 12.00);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  popped = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const RideEstimateSheet(
                      estimates: [sedan, suv],
                      pickupLat: 0,
                      pickupLng: 0,
                      dropoffLat: 0,
                      dropoffLng: 0,
                    ),
                  );
                },
                child: const Text('Open sheet'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open sheet'));
    await tester.pumpAndSettle();

    // Default selection is the first estimate; picking another changes the
    // value the confirm button pops with.
    await tester.tap(find.text('SUV'));
    await tester.pump();
    await tester.tap(find.text('Confirm Ride'));
    await tester.pumpAndSettle();

    expect(popped, 'suv');
  });

  testWidgets('an API estimate is labeled as not fully road-routed', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([
        const RideEstimate(vehicleType: 'sedan', total: 6.50, isEstimate: true),
      ]),
    );

    expect(find.text('Estimated fare — not fully road-routed'), findsOneWidget);
  });

  testWidgets('a multi-leg estimate lists the informational legs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([
        const RideEstimate(
          vehicleType: 'sedan',
          total: 6.50,
          legs: [
            RideEstimateLeg(distanceM: 1650, durationS: 150),
            RideEstimateLeg(distanceM: 820, durationS: 75),
          ],
        ),
      ]),
    );

    expect(find.text('Trip legs'), findsOneWidget);
    expect(find.text('Leg 1'), findsOneWidget);
    expect(find.text('Leg 2'), findsOneWidget);
    // 1650 m → 1.65 rounds down to 1.6 at one decimal; half-minutes round away
    // from zero.
    expect(find.text('1.6 km · ~3 min'), findsOneWidget);
    expect(find.text('0.8 km · ~1 min'), findsOneWidget);
  });

  testWidgets(
    'an estimate with legs renders the caption and the leg breakdown together',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        _sheet([
          const RideEstimate(
            vehicleType: 'sedan',
            total: 6.50,
            isEstimate: true,
            legs: [
              RideEstimateLeg(distanceM: 1650, durationS: 150),
              RideEstimateLeg(distanceM: 820, durationS: 75),
            ],
          ),
        ]),
      );

      // The landed `[fare]` shape: the honest `is_estimate` caption and the
      // informational per-leg lines coexist on the same selected option.
      expect(
        find.text('Estimated fare — not fully road-routed'),
        findsOneWidget,
      );
      expect(find.text('Trip legs'), findsOneWidget);
      expect(find.text('Leg 1'), findsOneWidget);
      expect(find.text('Leg 2'), findsOneWidget);
    },
  );

  testWidgets('a road-routed estimate without legs shows no estimate caption', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _sheet([const RideEstimate(vehicleType: 'sedan', total: 6.50)]),
    );

    expect(find.textContaining('Estimated fare'), findsNothing);
    expect(find.text('Trip legs'), findsNothing);
  });

  testWidgets('Confirm Ride is pinned and reachable on a 400x480 surface', (
    WidgetTester tester,
  ) async {
    await _pumpModal(tester, _fourEstimates);

    expect(find.text('Confirm Ride'), findsOneWidget);
    final confirm = tester.getRect(find.text('Confirm Ride'));
    expect(confirm.top, greaterThanOrEqualTo(0));
    expect(confirm.left, greaterThanOrEqualTo(0));
    expect(confirm.right, lessThanOrEqualTo(400));
    expect(confirm.bottom, lessThanOrEqualTo(480));
    expect(
      find.byKey(const ValueKey<String>('rider-sheet-scroll')),
      findsOneWidget,
    );
  });

  testWidgets('a one-option modal shrink-wraps below the 85% ceiling', (
    WidgetTester tester,
  ) async {
    await _pumpModal(tester, [
      const RideEstimate(vehicleType: 'sedan', total: 6.50, currency: '\$'),
    ]);

    // 400x480 surface, 85% ceiling = 408 px. A single short option must not
    // fill the whole constraint.
    final height = tester.getSize(find.byType(RideEstimateSheet)).height;
    expect(height, lessThan(480 * 0.85));
    expect(find.text('Confirm Ride'), findsOneWidget);
  });

  testWidgets('the estimate list scrolls to the last option', (
    WidgetTester tester,
  ) async {
    await _pumpModal(tester, _fourEstimates);

    final lastOption = find.text('van');
    expect(lastOption, findsOneWidget);
    final before = tester.getTopLeft(lastOption).dy;
    final confirmBefore = tester.getRect(find.text('Confirm Ride'));
    final scrollable = find.byKey(
      const ValueKey<String>('rider-sheet-scroll'),
    );
    final position = tester.state<ScrollableState>(
      find.descendant(of: scrollable, matching: find.byType(Scrollable)),
    ).position;
    final offsetBefore = position.pixels;

    await tester.drag(scrollable, const Offset(0, -160));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(lastOption).dy, lessThan(before));
    expect(position.pixels, greaterThan(offsetBefore));
    // The pinned action stayed put while the long list scrolled.
    expect(find.text('Confirm Ride'), findsOneWidget);
    expect(tester.getRect(find.text('Confirm Ride')), confirmBefore);
    expect(
      tester.getRect(find.text('Confirm Ride')).bottom,
      lessThanOrEqualTo(480),
    );
  });
}
