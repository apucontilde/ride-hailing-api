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
/// held ride).
WsEvent rideUpdated({
  String rideId = 'r1',
  String status = 'accepted',
  Map<String, dynamic>? fare,
  String? cancelledBy,
  bool includePlaces = false,
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
          'lat': tripPickupLat,
          'lng': tripPickupLng,
          'address': 'Central Park',
        },
      if (includePlaces)
        'dropoff': {
          'lat': tripDropoffLat,
          'lng': tripDropoffLng,
          'address': 'Airport',
        },
    },
  );
}