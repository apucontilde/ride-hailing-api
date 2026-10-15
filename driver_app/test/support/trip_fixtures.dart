import 'package:driver_app/core/network/ws_event.dart';

/// Shared trip fixtures for `trip_notifier_test.dart` and `trip_screen_test.dart`
/// so the two suites cannot drift on the coordinates or the `ride.updated` wire
/// shape.
const tripPickupLat = 9.9300;
const tripPickupLng = -84.0800;
const tripDropoffLat = 9.9500;
const tripDropoffLng = -84.1000;

/// Builds a `ride.updated` event in the backend's nested wire shape.
///
/// [includePlaces] adds the nested pickup/dropoff objects the dispatch accept
/// path delivers; a status-only patch omits them (the notifier merges onto the
/// held ride). [pickupLat]/[pickupLng]/[dropoffLat]/[dropoffLng] override the
/// fixture coordinates for a destination-only change.
WsEvent rideUpdated({
  String rideId = 'r1',
  String status = 'accepted',
  Map<String, dynamic>? fare,
  String? cancelledBy,
  bool includePlaces = false,
  double? pickupLat,
  double? pickupLng,
  String? pickupAddress,
  double? dropoffLat,
  double? dropoffLng,
  String? dropoffAddress,
}) {
  return WsEvent(
    type: WsEventType.updated,
    data: {
      'ride_id': rideId,
      'status': status,
      'fare': ?fare,
      'cancelled_by': ?cancelledBy,
      if (includePlaces)
        'pickup': {
          'lat': pickupLat ?? tripPickupLat,
          'lng': pickupLng ?? tripPickupLng,
          'address': pickupAddress ?? 'Central Park',
        },
      if (includePlaces)
        'dropoff': {
          'lat': dropoffLat ?? tripDropoffLat,
          'lng': dropoffLng ?? tripDropoffLng,
          'address': dropoffAddress ?? 'Airport',
        },
    },
  );
}
