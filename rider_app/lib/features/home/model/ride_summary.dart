class RideSummary {
  final String id;
  final String status;
  final String pickupAddress;
  final String dropoffAddress;
  final String vehicleType;
  final double totalFare;
  final String? requestedAt;
  final String? completedAt;

  const RideSummary({
    required this.id,
    required this.status,
    this.pickupAddress = '',
    this.dropoffAddress = '',
    this.vehicleType = '',
    this.totalFare = 0,
    this.requestedAt,
    this.completedAt,
  });

  factory RideSummary.fromJson(Map<String, dynamic> json) {
    return RideSummary(
      id: json['id'] as String? ?? '',
      status: json['status'] as String? ?? '',
      pickupAddress: json['pickup_address'] as String? ?? '',
      dropoffAddress: json['dropoff_address'] as String? ?? '',
      vehicleType: json['vehicle_type'] as String? ?? '',
      totalFare: (json['total_fare'] as num?)?.toDouble() ?? 0,
      requestedAt: json['requested_at'] as String?,
      completedAt: json['completed_at'] as String?,
    );
  }
}
