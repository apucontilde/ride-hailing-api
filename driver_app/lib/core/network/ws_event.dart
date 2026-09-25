/// Typed websocket event kinds the driver app can receive.
///
/// The backend wraps every message as `{"type": "...", "data": {...}}`; the
/// raw `type` string maps onto one of these. [other] catches any event the app
/// does not (yet) handle (`pong` keepalives, future admin messages, ...).
enum WsEventType {
  offer,
  updated,
  location,
  other;

  /// Maps a raw backend `type` string, e.g. `ride.offer`, onto the enum.
  static WsEventType fromRaw(String? raw) => switch (raw) {
        'ride.offer' => WsEventType.offer,
        'ride.updated' => WsEventType.updated,
        'driver.location' => WsEventType.location,
        _ => WsEventType.other,
      };
}

/// A normalized websocket event: the typed [type] plus the parsed [data]
/// payload (context-dependent — `ride_id` for offers, the full ride JSON for
/// `ride.updated`, lat/lng/heading/speed for `driver.location`).
class WsEvent {
  final WsEventType type;
  final Map<String, dynamic> data;

  const WsEvent({required this.type, required this.data});
}
