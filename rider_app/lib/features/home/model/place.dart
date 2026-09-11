class Place {
  final String id;
  final String name;
  final String address;
  final double lat;
  final double lng;
  final String? category;
  final double? distanceM;

  const Place({
    required this.id,
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    this.category,
    this.distanceM,
  });

  factory Place.fromJson(Map<String, dynamic> json) {
    return Place(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      address: json['address'] as String? ?? '',
      lat: (json['lat'] as num?)?.toDouble() ?? 0.0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0.0,
      category: json['category'] as String?,
      distanceM: (json['distance_m'] as num?)?.toDouble(),
    );
  }
}
