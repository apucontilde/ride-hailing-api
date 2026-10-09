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
}
