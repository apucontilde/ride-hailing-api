import 'fare.dart';

/// The authoritative ride object returned by `GET /api/v1/rides/{id}`
/// (Go `model.Ride`).
///
/// A strict superset of `RideSummary` (`ride_summary.dart`), which stays the
/// list-row shape for `/rides/history`. The fare block reuses [Fare] — the
/// `GET /rides/{id}/receipt` response is the same five numbers under a
/// `receipt` key, and this object carries them as `total_fare`.
class RideDetail {
  final String id;
  final String status;
  final String? driverId;
  final String pickupAddress;
  final String dropoffAddress;
  final String vehicleType;
  final Fare fare;
  final double cancellationFee;
  final String? requestedAt;
  final String? startedAt;
  final String? completedAt;
  final String? cancelledAt;

  const RideDetail({
    required this.id,
    required this.status,
    this.driverId,
    this.pickupAddress = '',
    this.dropoffAddress = '',
    this.vehicleType = '',
    this.fare = const Fare(total: 0),
    this.cancellationFee = 0,
    this.requestedAt,
    this.startedAt,
    this.completedAt,
    this.cancelledAt,
  });

  factory RideDetail.fromJson(Map<String, dynamic> json) {
    return RideDetail(
      id: json['id'] as String? ?? '',
      status: json['status'] as String? ?? '',
      driverId: json['driver_id'] as String?,
      pickupAddress: json['pickup_address'] as String? ?? '',
      dropoffAddress: json['dropoff_address'] as String? ?? '',
      vehicleType: json['vehicle_type'] as String? ?? '',
      fare: Fare(
        baseFare: (json['base_fare'] as num?)?.toDouble() ?? 0,
        distanceFare: (json['distance_fare'] as num?)?.toDouble() ?? 0,
        timeFare: (json['time_fare'] as num?)?.toDouble() ?? 0,
        surgeMultiplier: (json['surge_multiplier'] as num?)?.toDouble() ?? 1.0,
        total: (json['total_fare'] as num?)?.toDouble() ?? 0,
      ),
      cancellationFee: (json['cancellation_fee'] as num?)?.toDouble() ?? 0,
      requestedAt: json['requested_at'] as String?,
      startedAt: json['started_at'] as String?,
      completedAt: json['completed_at'] as String?,
      cancelledAt: json['cancelled_at'] as String?,
    );
  }

  /// `true` once the backend has a `total_fare`. A ride that has not been
  /// priced yet (or a `GET /rides/{id}` that raced the pricing write) reports
  /// zeroed numbers, which must not overwrite a fare the WS stream already
  /// delivered.
  bool get hasFare => fare.total > 0;
}
