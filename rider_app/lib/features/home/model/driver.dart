class NearbyDriver {
  final String driverId;
  final double lat;
  final double lng;
  final double heading;
  final double speed;
  final double distanceM;

  const NearbyDriver({
    required this.driverId,
    required this.lat,
    required this.lng,
    this.heading = 0,
    this.speed = 0,
    this.distanceM = 0,
  });

  factory NearbyDriver.fromJson(Map<String, dynamic> json) {
    return NearbyDriver(
      driverId: json['driver_id'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble() ?? 0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0,
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0,
    );
  }
}

class DriverInfo {
  final String id;
  final String firstName;
  final String? photoUrl;
  final double rating;
  final DriverVehicle? vehicle;
  final DriverLocation? location;

  const DriverInfo({
    required this.id,
    required this.firstName,
    this.photoUrl,
    this.rating = 5.0,
    this.vehicle,
    this.location,
  });

  factory DriverInfo.fromJson(Map<String, dynamic> json) {
    return DriverInfo(
      id: json['id'] as String? ?? '',
      firstName: json['first_name'] as String? ?? '',
      photoUrl: json['photo_url'] as String?,
      rating: (json['rating'] as num?)?.toDouble() ?? 5.0,
      vehicle: json['vehicle'] != null
          ? DriverVehicle.fromJson(json['vehicle'] as Map<String, dynamic>)
          : null,
      location: json['location'] != null
          ? DriverLocation.fromJson(json['location'] as Map<String, dynamic>)
          : null,
    );
  }
}

class DriverVehicle {
  final String make;
  final String model;
  final String color;
  final String plateNumber;

  const DriverVehicle({
    required this.make,
    required this.model,
    required this.color,
    required this.plateNumber,
  });

  factory DriverVehicle.fromJson(Map<String, dynamic> json) {
    return DriverVehicle(
      make: json['make'] as String? ?? '',
      model: json['model'] as String? ?? '',
      color: json['color'] as String? ?? '',
      plateNumber: json['plate_number'] as String? ?? '',
    );
  }
}

class DriverLocation {
  final String driverId;
  final double lat;
  final double lng;
  final double heading;
  final double speed;

  const DriverLocation({
    required this.driverId,
    required this.lat,
    required this.lng,
    this.heading = 0,
    this.speed = 0,
  });

  factory DriverLocation.fromJson(Map<String, dynamic> json) {
    return DriverLocation(
      driverId: json['driver_id'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      heading: (json['heading'] as num?)?.toDouble() ?? 0,
      speed: (json['speed'] as num?)?.toDouble() ?? 0,
    );
  }
}
