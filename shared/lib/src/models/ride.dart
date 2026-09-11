/// Ride model used by both apps. Mirrors the backend `Ride` JSON returned by
/// `GET /driver/rides/:id`, `GET /driver/rides/history`, and broadcast over
/// the websocket as `ride.updated` data.
class Ride {
  final String id;
  final String riderId;
  final String status; // pending|accepted|driver_arrived|in_progress|completed|cancelled
  final double? pickupLat;
  final double? pickupLng;
  final String? pickupAddress;
  final double? dropoffLat;
  final double? dropoffLng;
  final String? dropoffAddress;
  final String? vehicleType;
  final double? baseFare;
  final double? distanceFare;
  final double? timeFare;
  final double? surgeMultiplier;
  final double? totalFare;
  final String? requestedAt;
  final String? acceptedAt;
  final String? driverArrivedAt;
  final String? startedAt;
  final String? completedAt;
  final String? cancelledAt;
  final String? cancelledBy;

  const Ride({
    required this.id,
    required this.riderId,
    required this.status,
    this.pickupLat,
    this.pickupLng,
    this.pickupAddress,
    this.dropoffLat,
    this.dropoffLng,
    this.dropoffAddress,
    this.vehicleType,
    this.baseFare,
    this.distanceFare,
    this.timeFare,
    this.surgeMultiplier,
    this.totalFare,
    this.requestedAt,
    this.acceptedAt,
    this.driverArrivedAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
    this.cancelledBy,
  });

  factory Ride.fromJson(Map<String, dynamic> json) {
    double? asDouble(Object? value) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value);
      return null;
    }

    return Ride(
      id: json['id'] as String? ?? '',
      riderId: json['rider_id'] as String? ?? '',
      status: json['status'] as String? ?? '',
      pickupLat: asDouble(json['pickup_lat']),
      pickupLng: asDouble(json['pickup_lng']),
      pickupAddress: json['pickup_address'] as String?,
      dropoffLat: asDouble(json['dropoff_lat']),
      dropoffLng: asDouble(json['dropoff_lng']),
      dropoffAddress: json['dropoff_address'] as String?,
      vehicleType: json['vehicle_type'] as String?,
      baseFare: asDouble(json['base_fare']),
      distanceFare: asDouble(json['distance_fare']),
      timeFare: asDouble(json['time_fare']),
      surgeMultiplier: asDouble(json['surge_multiplier']),
      totalFare: asDouble(json['total_fare']),
      requestedAt: json['requested_at'] as String?,
      acceptedAt: json['accepted_at'] as String?,
      driverArrivedAt: json['driver_arrived_at'] as String?,
      startedAt: json['started_at'] as String?,
      completedAt: json['completed_at'] as String?,
      cancelledAt: json['cancelled_at'] as String?,
      cancelledBy: json['cancelled_by'] as String?,
    );
  }
}