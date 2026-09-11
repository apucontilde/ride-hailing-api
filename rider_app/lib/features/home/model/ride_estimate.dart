class RideEstimate {
  final String vehicleType;
  final double baseFare;
  final double distanceRate;
  final double timeRate;
  final double price;
  final String currency;
  final int etaSeconds;

  const RideEstimate({
    required this.vehicleType,
    this.baseFare = 0,
    this.distanceRate = 0,
    this.timeRate = 0,
    this.price = 0,
    this.currency = '\$',
    this.etaSeconds = 0,
  });

  factory RideEstimate.fromJson(Map<String, dynamic> json) {
    return RideEstimate(
      vehicleType: json['vehicle_type'] as String? ?? '',
      baseFare: (json['base_fare'] as num?)?.toDouble() ?? 0.0,
      distanceRate: (json['distance_rate'] as num?)?.toDouble() ?? 0.0,
      timeRate: (json['time_rate'] as num?)?.toDouble() ?? 0.0,
      price: (json['price'] as num?)?.toDouble() ?? 0.0,
      currency: json['currency'] as String? ?? '\$',
      etaSeconds: (json['eta_seconds'] as num?)?.toInt() ?? 0,
    );
  }

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

  String get formattedBaseFare => '$currency${baseFare.toStringAsFixed(2)}';
}
