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
  testWidgets('shows vehicle options and the computed total as the option price',
      (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
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
    ]));

    expect(find.text('Sedan'), findsOneWidget);
    expect(find.text('SUV'), findsOneWidget);
    expect(find.text('\$8.50'), findsOneWidget);
    expect(find.text('\$6.50'), findsNWidgets(2));
    expect(find.text('\$2.50'), findsOneWidget);
  });

  testWidgets('renders the API breakdown lines for the selected estimate',
      (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
      const RideEstimate(
        vehicleType: 'sedan',
        baseFare: 2.50,
        distanceFare: 3.10,
        timeFare: 0.90,
        surgeMultiplier: 1.20,
        total: 6.50,
        currency: '\$',
      ),
    ]));

    expect(find.text('Base fare'), findsOneWidget);
    expect(find.text('Distance fare'), findsOneWidget);
    expect(find.text('Time fare'), findsOneWidget);
    expect(find.text('Conditions multiplier'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(find.text('\$3.10'), findsOneWidget);
    expect(find.text('×1.20'), findsOneWidget);
  });

  testWidgets('renders the API currency when sent', (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
      const RideEstimate(
        vehicleType: 'sedan',
        baseFare: 2.50,
        total: 6.50,
        currency: 'USD',
      ),
    ]));

    expect(find.text('USD6.50'), findsNWidgets(2));
    expect(find.text('USD2.50'), findsOneWidget);
  });

  testWidgets('omits currency when the API did not send one',
      (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
      const RideEstimate(vehicleType: 'sedan', baseFare: 2.50, total: 6.50),
    ]));

    expect(find.text('6.50'), findsNWidgets(2));
    expect(find.textContaining('USD'), findsNothing);
  });

  testWidgets('a zero or absent grade uplift adds no line',
      (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
      const RideEstimate(vehicleType: 'sedan', total: 6.50),
    ]));

    expect(find.textContaining('climb'), findsNothing);
  });

  testWidgets('a non-zero grade uplift annotates the distance leg',
      (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
      const RideEstimate(
        vehicleType: 'sedan',
        distanceFare: 3.10,
        total: 6.50,
        gradeUpliftPct: 0.05,
      ),
    ]));

    expect(find.text('climb +5.0%'), findsOneWidget);
  });

  testWidgets('shows confirm ride button', (WidgetTester tester) async {
    await tester.pumpWidget(_sheet([
      const RideEstimate(vehicleType: 'sedan', baseFare: 10.00, total: 10.00),
    ]));

    expect(find.text('Confirm Ride'), findsOneWidget);
  });
}
