import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../config.dart';
import '../api/endpoints.dart';
import 'ws_event.dart';

export 'package:ride_hailing_shared/ride_hailing_shared.dart'
    show WebSocketService;

final webSocketServiceProvider = Provider<WebSocketService>((ref) {
  return WebSocketService(baseUrl: ApiConfig.baseUrl, wsPath: ApiEndpoints.ws);
});

/// Driver-app facade over the shared [WebSocketService].
///
/// The shared service owns the wire (connect/reconnect/send helpers); this
/// wrapper normalizes the raw `{type, data}` broadcasts into typed [WsEvent]s
/// so notifiers (the ride-state machine) never parse JSON and the nested-send
/// contract (accept/decline/ping) is preserved unchanged.
class DriverWebSocketService {
  DriverWebSocketService(this._inner);

  final WebSocketService _inner;

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
}

final driverWebSocketServiceProvider = Provider<DriverWebSocketService>((ref) {
  return DriverWebSocketService(ref.read(webSocketServiceProvider));
});
