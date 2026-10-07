import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('formatMoney', () {
    test('renders major-unit amounts at two decimals, never whole dollars', () {
      expect(formatMoney(12.4), '12.40');
      expect(formatMoney(12.0), '12.00');
      expect(formatMoney(0), '0.00');
      expect(formatMoney(6.5), '6.50');
    });

    test('prefixes the API currency code when present', () {
      expect(formatMoney(12.4, currency: 'USD'), 'USD12.40');
    });

    test('renders bare when the currency is absent or empty', () {
      expect(formatMoney(12.4), '12.40');
      expect(formatMoney(12.4, currency: ''), '12.40');
    });
  });

  group('Ride fare audit fields', () {
    test('parses the currency and grade uplift the ride JSON carries', () {
      final ride = Ride.fromJson({
        'id': 'r1',
        'rider_id': 'u1',
        'status': 'completed',
        'total_fare': 11.8,
        'fare_currency': 'USD',
        'grade_uplift_pct': 0.05,
      });

      expect(ride.fareCurrency, 'USD');
      expect(ride.gradeUpliftPct, 0.05);
    });

    test('leaves the audit fields null for a legacy ride', () {
      final ride = Ride.fromJson({
        'id': 'r1',
        'rider_id': 'u1',
        'status': 'completed',
        'total_fare': 11.8,
      });

      expect(ride.fareCurrency, isNull);
      expect(ride.gradeUpliftPct, isNull);
    });
  });
}
