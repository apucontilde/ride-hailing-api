import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/presentation/ride_estimate_sheet.dart';
import 'package:rider_app/features/home/model/ride_estimate.dart';

void main() {
  testWidgets('shows vehicle options', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RideEstimateSheet(
          estimates: [
            const RideEstimate(
              vehicleType: 'sedan',
              baseFare: 15.50,
              price: 15.50,
              currency: '\$',
              etaSeconds: 300,
            ),
            const RideEstimate(
              vehicleType: 'suv',
              baseFare: 25.00,
              price: 25.00,
              currency: '\$',
              etaSeconds: 420,
            ),
          ],
          pickupLat: 0,
          pickupLng: 0,
          dropoffLat: 0,
          dropoffLng: 0,
        ),
      ),
    ));

    expect(find.text('Sedan'), findsOneWidget);
    expect(find.text('SUV'), findsOneWidget);
    expect(find.text('\$15.50'), findsOneWidget);
    expect(find.text('\$25.00'), findsOneWidget);
  });

  testWidgets('shows confirm ride button', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RideEstimateSheet(
          estimates: [
            const RideEstimate(
              vehicleType: 'sedan',
              baseFare: 10.00,
              price: 10.00,
              currency: '\$',
              etaSeconds: 180,
            ),
          ],
          pickupLat: 0,
          pickupLng: 0,
          dropoffLat: 0,
          dropoffLng: 0,
        ),
      ),
    ));

    expect(find.text('Confirm Ride'), findsOneWidget);
  });
}
