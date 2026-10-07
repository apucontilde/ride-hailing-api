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
    );
  }

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
