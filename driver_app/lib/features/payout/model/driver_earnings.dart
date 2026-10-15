import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// The driver earnings ledger, exactly as `GET /driver/me/earnings` and the
/// `earnings` half of `POST /driver/earnings/withdraw` return it.
///
/// **Money-unit boundary:** these endpoints are the documented exception to the
/// ride JSON's major-units rule — every money field here is an **integer cent**.
/// Convert exactly once, at render, through [formatCents]; never treat a
/// `_cents` value as dollars and never divide anywhere else.
///
/// The envelope key is `earnings` (not `summary`). The server owns the
/// currency (`PAYOUT_CURRENCY`); a blank or absent code renders bare rather
/// than inventing a `$`.
class DriverEarningsSummary {
  /// The withdrawable balance: available credits minus pending withdrawal
  /// debits.
  final int availableCents;

  /// Pending **credit** (money not yet available to withdraw).
  final int pendingCents;

  /// The gross of pending + paid withdrawal debits.
  final int withdrawnCents;

  /// The gross of every credit row ever (ride earnings, tips, adjustments).
  final int lifetimeCents;

  /// The ledger's ISO-4217 code, or `null` when the server sent none. Rendered
  /// as a prefix when present; never invented.
  final String? currency;

  /// Fares credited in the current (UTC) calendar month.
  final int monthTotalCents;
  final int monthTrips;

  /// Every `ride_earning` row ever.
  final int completedTrips;

  /// The monthly breakdown, newest first.
  final List<DriverEarningsMonth> months;

  const DriverEarningsSummary({
    required this.availableCents,
    required this.pendingCents,
    required this.withdrawnCents,
    required this.lifetimeCents,
    required this.currency,
    required this.monthTotalCents,
    required this.monthTrips,
    required this.completedTrips,
    required this.months,
  });

  /// A zeroed summary for a driver with no ledger rows. A missing driver is a
  /// zero balance, never a 404.
  static const empty = DriverEarningsSummary(
    availableCents: 0,
    pendingCents: 0,
    withdrawnCents: 0,
    lifetimeCents: 0,
    currency: null,
    monthTotalCents: 0,
    monthTrips: 0,
    completedTrips: 0,
    months: [],
  );

  factory DriverEarningsSummary.fromJson(Map<String, dynamic> json) {
    final rawCurrency = json['currency'];
    final currency = rawCurrency is String ? rawCurrency : '';
    final months = (json['months'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DriverEarningsMonth.fromJson)
        .toList()
      // The server already orders newest-first; sort defensively so a server
      // reorder cannot turn the card's month list upside down.
      ..sort((a, b) => b.month.compareTo(a.month));
    return DriverEarningsSummary(
      availableCents: _asInt(json['available_cents']),
      pendingCents: _asInt(json['pending_cents']),
      withdrawnCents: _asInt(json['withdrawn_cents']),
      lifetimeCents: _asInt(json['lifetime_cents']),
      currency: currency.isEmpty ? null : currency,
      monthTotalCents: _asInt(json['month_total_cents']),
      monthTrips: _asInt(json['month_trips']),
      completedTrips: _asInt(json['completed_trips']),
      months: months,
    );
  }
}

/// One `"YYYY-MM"` bucket of the ledger's credit rows.
class DriverEarningsMonth {
  /// The first instant of the month, for sorting and comparison.
  final DateTime month;
  final int totalCents;
  final int trips;

  const DriverEarningsMonth({
    required this.month,
    required this.totalCents,
    required this.trips,
  });

  factory DriverEarningsMonth.fromJson(Map<String, dynamic> json) {
    return DriverEarningsMonth(
      month: _parseMonth(json['month']),
      totalCents: _asInt(json['total_cents']),
      trips: _asInt(json['trips']),
    );
  }

  /// e.g. `September 2026`. Hand-rolled because `intl` is not a dependency.
  String get label => '${_monthNames[month.month - 1]} ${month.year}';

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}

/// One `driver_earnings` ledger row of `kind = 'withdrawal'`, as the withdraw
/// response returns it. Lenient on purpose: an unknown/missing key must never
/// throw. [status] and [amountCents] are parsed, but **no UI renders them
/// today** — the server only ever records `pending`, so the sheet's pending
/// copy is unconditional (a future non-`pending` status is not [isPending]).
class DriverWithdrawal {
  /// `pending` while the debit is recorded but no money has moved.
  final String status;
  final int amountCents;

  const DriverWithdrawal({required this.status, required this.amountCents});

  bool get isPending => status == 'pending';

  factory DriverWithdrawal.fromJson(Map<String, dynamic> json) {
    return DriverWithdrawal(
      status: json['status'] as String? ?? '',
      amountCents: _asInt(json['amount_cents']),
    );
  }
}

/// The `200` body of `POST /driver/earnings/withdraw`: the recorded ledger
/// debit plus the updated summary the server computed inside the same lock.
class WithdrawalResult {
  final DriverWithdrawal withdrawal;
  final DriverEarningsSummary earnings;

  const WithdrawalResult({required this.withdrawal, required this.earnings});
}

/// Renders an **integer cent** amount through the single shared money
/// convention: convert to major units exactly once, here, and let
/// [formatMoney] do the two-decimal formatting and the currency prefix.
///
/// `formatCents(2500, currency: 'USD')` → `USD25.00`; a null currency is bare.
String formatCents(int cents, {String? currency}) =>
    formatMoney(cents / 100, currency: currency);

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

/// Parses the server's `"YYYY-MM"` month. Falls back to a full ISO parse, then
/// to an epoch sentinel so a malformed value cannot throw.
DateTime _parseMonth(Object? raw) {
  if (raw is String) {
    final parts = raw.split('-');
    if (parts.length >= 2) {
      final year = int.tryParse(parts[0].trim());
      final month = int.tryParse(parts[1].trim());
      if (year != null && month != null && month >= 1 && month <= 12) {
        return DateTime(year, month);
      }
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed != null) return parsed;
  }
  return DateTime(1970, 1);
}
