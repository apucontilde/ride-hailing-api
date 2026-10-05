import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../api/endpoints.dart';
import 'ws_event.dart';

export 'package:ride_hailing_shared/ride_hailing_shared.dart'
    show WebSocketService;

final webSocketServiceProvider = Provider<WebSocketService>((ref) {
  return WebSocketService(
    baseUrl: ApiConfig.baseUrl,
    wsPath: ApiEndpoints.ws,
    // Driver-only keep-alive (the shared default is off): a ping every 25 s
    // keeps an idle socket from dying silently, so dispatch's hub-presence
    // gate sees a live driver instead of skipping them as "no socket".
    heartbeatInterval: const Duration(seconds: 25),
  );
});

/// Driver-app facade over the shared [WebSocketService].
///
/// The shared service owns the wire (connect/reconnect/send helpers); this
/// wrapper normalizes the raw `{type, data}` broadcasts into typed [WsEvent]s
/// so notifiers (the ride-state machine) never parse JSON and the nested-send
/// contract (accept/decline/ping) is preserved unchanged.
class DriverWebSocketService {
  DriverWebSocketService(this._inner) {
    // Re-arm on every (re)connect: re-publish the last known fix (via
    // [onReconnected]) and ping immediately, so a driver whose socket just
    // reconnected is dispatchable now rather than a full heartbeat later.
    _inner.onConnected = _handleConnected;
  }

  final WebSocketService _inner;

  /// Last availability seen from [setOnline]; used to re-apply the right
  /// heartbeat state when a reconnect re-fires `onConnected`.
  bool _online = false;

  /// Invoked after every (re)connect, before the immediate ping. The app wires
  /// this to `LocationService.publishLastPosition`.
  void Function()? onReconnected;

  void _handleConnected() {
    onReconnected?.call();
    if (_online) {
      // A reconnect of an online driver must be immediately re-eligible.
      _inner.startHeartbeat();
      _inner.ping();
    } else {
      // An offline driver who happened to reconnect must not start pinging.
      _inner.stopHeartbeat();
    }
  }

  /// Typed view over the shared broadcast stream.
  late final Stream<WsEvent> events = _inner.events.map(_normalize);

  static WsEvent _normalize(Map<String, dynamic> raw) {
    return WsEvent(
      type: WsEventType.fromRaw(raw['type'] as String?),
      data: raw['data'] as Map<String, dynamic>? ?? const <String, dynamic>{},
    );
  }

  Future<void> connect({required String token}) => _inner.connect(token: token);
  Future<void> disconnect() => _inner.disconnect();
  bool get isConnected => _inner.isConnected;
  void acceptOffer(String rideId) => _inner.acceptOffer(rideId);
  void declineOffer(String rideId) => _inner.declineOffer(rideId);
  void ping() => _inner.ping();
  void dispose() => _inner.dispose();

  /// Tracks the driver's availability: online (re)starts the keep-alive
  /// heartbeat and pings once immediately; offline stops it. The timer is
  /// owned by the shared service and also stops on disconnect/dispose.
  void setOnline(bool online) {
    _online = online;
    if (online) {
      _inner.startHeartbeat();
      _inner.ping();
    } else {
      _inner.stopHeartbeat();
    }
  }
}

final driverWebSocketServiceProvider = Provider<DriverWebSocketService>((ref) {
  return DriverWebSocketService(ref.read(webSocketServiceProvider));
});
