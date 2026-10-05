/// One ordered waypoint of a ride, from the `stops` array that
/// `GET /api/v1/rides/:id`, `GET /api/v1/rides/current` and
/// `PUT /api/v1/rides/:id/destination` return as a sibling of `ride`
/// (Go `model.RideStop`, migration 016).
///
/// The final stop (`kind == 'destination'`) mirrors the ride's own
/// `dropoff_lat`/`dropoff_lng`, so a caller building a route must not append
/// the dropoff again when it is present. `GET` answers have always carried a
/// `stops` key (empty for a pre-multi-stop ride), but a client must still
/// degrade when the key is absent — see `trip_route_provider.dart`.
class RideStop {
  final int sequence;
  final String kind;
  final double lat;
  final double lng;
  final String address;

  const RideStop({
    required this.sequence,
    required this.kind,
    required this.lat,
    required this.lng,
    this.address = '',
  });

  factory RideStop.fromJson(Map<String, dynamic> json) {
    return RideStop(
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      kind: json['kind'] as String? ?? 'stop',
      lat: (json['lat'] as num?)?.toDouble() ?? 0,
      lng: (json['lng'] as num?)?.toDouble() ?? 0,
      address: json['address'] as String? ?? '',
    );
  }

  bool get isDestination => kind == 'destination';
}
