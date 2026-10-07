import 'package:flutter_test/flutter_test.dart';
import 'package:rider_app/features/home/model/ride_estimate.dart';

/// The `GET /estimates/price` estimate body
/// (RIDER_API_GUIDE.md `### Price estimates`).
Map<String, dynamic> estimateJson({
  double baseFare = 2.5,
  double distanceFare = 3.1,
  double timeFare = 0.9,
  double surgeMultiplier = 1.0,
  double total = 6.5,
  double gradeUpliftPct = 0.0,
}) =>
    {
      'vehicle_type': 'sedan',
      'base_fare': baseFare,
      'distance_rate': 1.5,
      'time_rate': 0.4,
      'distance_fare': distanceFare,
      'time_fare': timeFare,
      'surge_multiplier': surgeMultiplier,
      'total': total,
      'region_id': 'cr-sj',
      'currency': 'USD',
      'demand_multiplier': 1.0,
      'supply_multiplier': 1.0,
      'grade_uplift_pct': gradeUpliftPct,
    };

void main() {
  group('RideEstimate.fromJson', () {
    test('maps the API total and breakdown legs', () {
      final estimate = RideEstimate.fromJson(estimateJson());

      expect(estimate.baseFare, 2.5);
      expect(estimate.distanceFare, 3.1);
      expect(estimate.timeFare, 0.9);
      expect(estimate.total, 6.5);
      expect(estimate.surgeMultiplier, 1.0);
      expect(estimate.demandMultiplier, 1.0);
      expect(estimate.supplyMultiplier, 1.0);
      expect(estimate.currency, 'USD');
      expect(estimate.gradeUpliftPct, 0.0);
    });

    test('no longer reads the dead price field', () {
      final estimate = RideEstimate.fromJson({
        'vehicle_type': 'sedan',
        'price': 99.0,
      });

      expect(estimate.total, 0.0);
      expect(estimate.formattedTotal, '0.00');
    });

    test('renders the API currency as the amount prefix', () {
      expect(RideEstimate.fromJson(estimateJson()).formattedTotal, 'USD6.50');
    });

    test('omits the currency when the API did not send one', () {
      final estimate = RideEstimate.fromJson({
        'vehicle_type': 'sedan',
        'total': 6.5,
      });

      expect(estimate.currency, '');
      expect(estimate.formattedTotal, '6.50');
    });

    test('flags only a non-zero grade uplift', () {
      expect(RideEstimate.fromJson(estimateJson()).hasGradeUplift, isFalse);
      expect(
        RideEstimate.fromJson(estimateJson(gradeUpliftPct: 0.05)).hasGradeUplift,
        isTrue,
      );
      expect(
        RideEstimate.fromJson({'vehicle_type': 'sedan'}).hasGradeUplift,
        isFalse,
      );
    });
  });
}
