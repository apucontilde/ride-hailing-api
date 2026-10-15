import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/features/payout/model/driver_earnings.dart';

/// Pure model/parse cases: the money-unit boundary and the lenient decode that
/// keeps a malformed server field from throwing inside the earnings card.
void main() {
  group('DriverEarningsSummary.fromJson', () {
    test('maps every cent field and the currency', () {
      final summary = DriverEarningsSummary.fromJson(const {
        'available_cents': 2000,
        'pending_cents': 500,
        'withdrawn_cents': 1000,
        'lifetime_cents': 2500,
        'currency': 'USD',
        'month_total_cents': 2550,
        'month_trips': 2,
        'completed_trips': 5,
      });

      expect(summary.availableCents, 2000);
      expect(summary.pendingCents, 500);
      expect(summary.withdrawnCents, 1000);
      expect(summary.lifetimeCents, 2500);
      expect(summary.currency, 'USD');
      expect(summary.monthTotalCents, 2550);
      expect(summary.monthTrips, 2);
      expect(summary.completedTrips, 5);
    });

    test('defaults missing fields to zero and a null currency', () {
      final summary = DriverEarningsSummary.fromJson(const {});

      expect(summary.availableCents, 0);
      expect(summary.lifetimeCents, 0);
      expect(summary.currency, isNull);
      expect(summary.months, isEmpty);
    });

    test('a blank currency code is treated as no currency', () {
      final summary = DriverEarningsSummary.fromJson(const {'currency': ''});

      expect(summary.currency, isNull);
    });

    test('coerces numeric strings and rounds doubles rather than throwing', () {
      final summary = DriverEarningsSummary.fromJson(const {
        'available_cents': '2000',
        'lifetime_cents': 2500.4,
        'pending_cents': 500.6,
      });

      expect(summary.availableCents, 2000);
      expect(summary.lifetimeCents, 2500);
      expect(summary.pendingCents, 501);
    });

    test('sorts the monthly breakdown newest first', () {
      final summary = DriverEarningsSummary.fromJson(const {
        'months': [
          {'month': '2026-07', 'total_cents': 300, 'trips': 1},
          {'month': '2026-09', 'total_cents': 1000, 'trips': 2},
          {'month': '2026-08', 'total_cents': 700, 'trips': 1},
        ],
      });

      expect(
        summary.months.map((m) => m.label).toList(),
        ['September 2026', 'August 2026', 'July 2026'],
      );
    });
  });

  group('DriverEarningsMonth', () {
    test('labels the month and carries the cents', () {
      final month = DriverEarningsMonth.fromJson(const {
        'month': '2026-09',
        'total_cents': 1000,
        'trips': 2,
      });

      expect(month.label, 'September 2026');
      expect(month.totalCents, 1000);
      expect(month.trips, 2);
    });

    test('a malformed month does not throw', () {
      final month = DriverEarningsMonth.fromJson(const {'month': 'nonsense'});

      expect(month.totalCents, 0);
      expect(month.trips, 0);
    });
  });

  group('DriverWithdrawal.fromJson', () {
    test('reads status and the negative debit amount', () {
      final withdrawal = DriverWithdrawal.fromJson(const {
        'status': 'pending',
        'amount_cents': -1500,
      });

      expect(withdrawal.status, 'pending');
      expect(withdrawal.isPending, isTrue);
      // A withdrawal is a ledger debit: the server sends a negative amount.
      expect(withdrawal.amountCents, -1500);
    });

    test('an absent status is not pending and does not throw', () {
      final withdrawal = DriverWithdrawal.fromJson(const {});

      expect(withdrawal.isPending, isFalse);
      expect(withdrawal.amountCents, 0);
    });
  });

  group('formatCents', () {
    test('converts cents to major units exactly once', () {
      expect(formatCents(2500, currency: 'USD'), 'USD25.00');
      expect(formatCents(5, currency: 'CRC'), 'CRC0.05');
    });

    test('renders bare when there is no currency', () {
      expect(formatCents(2500), '25.00');
    });

    test('zero is 0.00, never blank', () {
      expect(formatCents(0), '0.00');
      expect(formatCents(0, currency: 'USD'), 'USD0.00');
    });
  });
}
