import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// A `ride.updated` broadcast payload normalized onto the flat [Ride] model.
///
/// The two wire shapes differ (`driver_app_plans/04`):
/// - **WS `ride.updated`** (`internal/websocket.RideUpdateData`): the ride is
///   keyed `ride_id` (not `id`), the places arrive as nested `pickup` /
///   `dropoff` objects, the fare as a nested `fare` object, and **only the
///   fields that changed are present** — a `driver_arrived` event carries
///   nothing but `ride_id` + `status`.
/// - **REST** (`model.Ride`, e.g. `GET /driver/rides/:id`, the status/cancel
///   responses and the `GET /driver/rides/current` restore): flat `id`,
///   `pickup_lat`, `total_fare`, ...
///
/// Because the event is a *patch*, [applyTo] merges it onto the ride the
/// driver already holds instead of replacing it — otherwise every broadcast
/// would drop the pickup/dropoff coordinates and the id the app needs to make
/// the next call.
class RideUpdate {
  final String rideId;
  final String status;
  final String? cancelledBy;
  final double? pickupLat;
  final double? pickupLng;
  final String? pickupAddress;
  final double? dropoffLat;
  final double? dropoffLng;
  final String? dropoffAddress;
  final double? baseFare;
  final double? distanceFare;
  final double? timeFare;
  final double? surgeMultiplier;
  final double? totalFare;

  const RideUpdate({
    required this.rideId,
    required this.status,
    this.cancelledBy,
    this.pickupLat,
    this.pickupLng,
    this.pickupAddress,
    this.dropoffLat,
    this.dropoffLng,
    this.dropoffAddress,
    this.baseFare,
    this.distanceFare,
    this.timeFare,
    this.surgeMultiplier,
    this.totalFare,
  });

  factory RideUpdate.fromJson(Map<String, dynamic> json) {
    final pickup = _asMap(json['pickup']);
    final dropoff = _asMap(json['dropoff']);
    final fare = _asMap(json['fare']);
    return RideUpdate(
      rideId: (json['ride_id'] ?? json['id']) as String? ?? '',
      status: json['status'] as String? ?? '',
      cancelledBy: json['cancelled_by'] as String?,
      pickupLat: _asDouble(pickup?['lat']) ?? _asDouble(json['pickup_lat']),
      pickupLng: _asDouble(pickup?['lng']) ?? _asDouble(json['pickup_lng']),
      pickupAddress: pickup?['address'] as String? ?? json['pickup_address'] as String?,
      dropoffLat: _asDouble(dropoff?['lat']) ?? _asDouble(json['dropoff_lat']),
      dropoffLng: _asDouble(dropoff?['lng']) ?? _asDouble(json['dropoff_lng']),
      dropoffAddress: dropoff?['address'] as String? ?? json['dropoff_address'] as String?,
      baseFare: _asDouble(fare?['base_fare']) ?? _asDouble(json['base_fare']),
      distanceFare: _asDouble(fare?['distance_fare']) ?? _asDouble(json['distance_fare']),
      timeFare: _asDouble(fare?['time_fare']) ?? _asDouble(json['time_fare']),
      surgeMultiplier: _asDouble(fare?['surge_multiplier']) ?? _asDouble(json['surge_multiplier']),
      totalFare: _asDouble(fare?['total']) ?? _asDouble(json['total_fare']),
    );
  }

  /// Merges this patch onto [current]. Fields the event omits keep the value
  /// they already had; a mismatched (or absent) [current] starts a fresh ride.
  Ride applyTo(Ride? current) {
    final base = current != null && current.id == rideId ? current : null;
    return Ride(
      id: rideId.isNotEmpty ? rideId : (base?.id ?? ''),
      riderId: base?.riderId ?? '',
      status: status.isNotEmpty ? status : (base?.status ?? ''),
      pickupLat: pickupLat ?? base?.pickupLat,
      pickupLng: pickupLng ?? base?.pickupLng,
      pickupAddress: pickupAddress ?? base?.pickupAddress,
      dropoffLat: dropoffLat ?? base?.dropoffLat,
      dropoffLng: dropoffLng ?? base?.dropoffLng,
      dropoffAddress: dropoffAddress ?? base?.dropoffAddress,
      vehicleType: base?.vehicleType,
      baseFare: baseFare ?? base?.baseFare,
      distanceFare: distanceFare ?? base?.distanceFare,
      timeFare: timeFare ?? base?.timeFare,
      surgeMultiplier: surgeMultiplier ?? base?.surgeMultiplier,
      totalFare: totalFare ?? base?.totalFare,
      requestedAt: base?.requestedAt,
      acceptedAt: base?.acceptedAt,
      driverArrivedAt: status == 'driver_arrived' ? DateTime.now().toIso8601String() : base?.driverArrivedAt,
      startedAt: status == 'in_progress' ? DateTime.now().toIso8601String() : base?.startedAt,
      completedAt: status == 'completed' ? DateTime.now().toIso8601String() : base?.completedAt,
      cancelledAt: status == 'cancelled' ? DateTime.now().toIso8601String() : base?.cancelledAt,
      cancelledBy: cancelledBy ?? base?.cancelledBy,
    );
  }

  static Map<String, dynamic>? _asMap(Object? value) =>
      value is Map<String, dynamic> ? value : null;

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }
}
