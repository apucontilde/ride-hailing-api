class Fare {
  final double baseFare;
  final double distanceFare;
  final double timeFare;
  final double surgeMultiplier;
  final double total;

  const Fare({
    this.baseFare = 0,
    this.distanceFare = 0,
    this.timeFare = 0,
    this.surgeMultiplier = 1.0,
    required this.total,
  });

  factory Fare.fromJson(Map<String, dynamic> json) {
    return Fare(
      baseFare: (json['base_fare'] as num?)?.toDouble() ?? 0,
      distanceFare: (json['distance_fare'] as num?)?.toDouble() ?? 0,
      timeFare: (json['time_fare'] as num?)?.toDouble() ?? 0,
      surgeMultiplier: (json['surge_multiplier'] as num?)?.toDouble() ?? 1.0,
      total: (json['total'] as num?)?.toDouble() ?? 0,
    );
  }
}