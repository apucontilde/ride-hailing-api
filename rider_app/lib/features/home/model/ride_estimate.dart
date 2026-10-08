/// One leg of a waypoint-aware estimate (`POST /estimates/price` `legs[]`).
///
/// The API returns one entry per consecutive itinerary pair (stops + 1, always
/// at least one). `distanceFare`/`timeFare` are the informational pre-conditions
/// breakdown: they exclude the once-per-trip base and the multiplier, and they
/// are never summed by the client — `RideEstimate.total` stays authoritative.
class RideEstimateLeg {
  final int distanceM;
  final int durationS;
  final double distanceFare;
  final double timeFare;

  const RideEstimateLeg({
    this.distanceM = 0,
    this.durationS = 0,
    this.distanceFare = 0,
    this.timeFare = 0,
  });

  factory RideEstimateLeg.fromJson(Map<String, dynamic> json) {
    return RideEstimateLeg(
      distanceM: (json['distance_m'] as num?)?.toInt() ?? 0,
      durationS: (json['duration_s'] as num?)?.toInt() ?? 0,
      distanceFare: (json['distance_fare'] as num?)?.toDouble() ?? 0.0,
      timeFare: (json['time_fare'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class RideEstimate {
  final String vehicleType;
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double surgeMultiplier;
  final double demandMultiplier;
  final double supplyMultiplier;
  final double total;
  final String currency;
  final int etaSeconds;
  final double gradeUpliftPct;

  /// The API's `is_estimate`: the whole itinerary was priced as a straight-line
  /// estimate (part of it is outside mapped coverage / crosses regions). The
  /// fare UI must say so rather than present it as a road-routed quote.
  final bool isEstimate;

  /// The additive per-leg breakdown. Always present from the API (length =
  /// stops + 1); an absent field parses to an empty list for older mocks.
  final List<RideEstimateLeg> legs;

  const RideEstimate({
    required this.vehicleType,
    this.baseFare = 0,
    this.distanceFare = 0,
    this.timeFare = 0,
    this.surgeMultiplier = 1.0,
    this.demandMultiplier = 1.0,
    this.supplyMultiplier = 1.0,
    this.total = 0,
    this.currency = '',
    this.etaSeconds = 0,
    this.gradeUpliftPct = 0,
    this.isEstimate = false,
    this.legs = const [],
  });

  factory RideEstimate.fromJson(Map<String, dynamic> json) {
    return RideEstimate(
      vehicleType: json['vehicle_type'] as String? ?? '',
      baseFare: (json['base_fare'] as num?)?.toDouble() ?? 0.0,
      distanceFare: (json['distance_fare'] as num?)?.toDouble() ?? 0.0,
      timeFare: (json['time_fare'] as num?)?.toDouble() ?? 0.0,
      surgeMultiplier: (json['surge_multiplier'] as num?)?.toDouble() ?? 1.0,
      demandMultiplier: (json['demand_multiplier'] as num?)?.toDouble() ?? 1.0,
      supplyMultiplier: (json['supply_multiplier'] as num?)?.toDouble() ?? 1.0,
      total: (json['total'] as num?)?.toDouble() ?? 0.0,
      currency: json['currency'] as String? ?? '',
      etaSeconds: (json['eta_seconds'] as num?)?.toInt() ?? 0,
      gradeUpliftPct: (json['grade_uplift_pct'] as num?)?.toDouble() ?? 0.0,
      isEstimate: json['is_estimate'] == true,
      legs: (json['legs'] as List<dynamic>? ?? [])
          .map((leg) =>
              RideEstimateLeg.fromJson(leg as Map<String, dynamic>))
          .toList(),
    );
  }

  /// Whether the API returned more than one leg, i.e. the estimate covers an
  /// actual stop itinerary rather than a single pickup→dropoff trip.
  bool get hasMultipleLegs => legs.length > 1;

  /// The API's climb uplift is a fraction of the distance leg. The `[fare]`
  /// grade-uplift stage has landed (migration `020_grade_uplift`), so the
  /// estimate carries a real value. A zero or absent uplift must add no line to
  /// the estimate.
  bool get hasGradeUplift => gradeUpliftPct != 0;

  String get formattedTotal => formatMoney(total);

  String get formattedBaseFare => formatMoney(baseFare);

  String get formattedDistanceFare => formatMoney(distanceFare);

  String get formattedTimeFare => formatMoney(timeFare);

  /// Formats a major-unit amount with the API currency as the prefix, matching
  /// the completion receipt's two-decimal presentation. The currency is never
  /// invented: an absent/empty code renders the bare amount.
  String formatMoney(double value) => '$currency${value.toStringAsFixed(2)}';

  String get displayName {
    switch (vehicleType) {
      case 'sedan':
        return 'Sedan';
      case 'suv':
        return 'SUV';
      case 'premium':
        return 'Premium';
      default:
        return vehicleType;
    }
  }

  int get capacity {
    switch (vehicleType) {
      case 'sedan':
        return 4;
      case 'suv':
        return 6;
      case 'premium':
        return 4;
      default:
        return 4;
    }
  }
}
