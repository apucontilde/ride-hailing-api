import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Shared websocket service used by both the rider and driver apps.
///
/// The driver both *receives* events (`ride.offer`, `ride.updated`,
/// `driver.location`) and *sends* control messages (`ride.accept`,
/// `ride.decline`, `ping`). The rider receives `ride.updated` broadcasts and
/// keeps the connection alive with `ping`.
///
/// Payloads use the backend's nested shape:
///
/// ```json
/// {"type": "ride.accept", "data": {"ride_id": "..."}}
/// ```
///
/// (The backend hub unmarshals `ride_id` out of `incoming.Data`, so the flat
/// `{"type": "...", "ride_id": ...}` form shown in some docs does not work.)
class WebSocketService {
  final String baseUrl;
  final String wsPath;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  String? _accessToken;
  bool _shouldReconnect = false;
  bool _isDisposed = false;
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController.broadcast();

  WebSocketService({String? baseUrl, this.wsPath = '/ws'})
      : baseUrl = baseUrl ?? 'http://localhost:8080';

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  Future<void> connect({required String token}) async {
    if (_isDisposed) return;
    if (_channel != null && _accessToken == token) return;

    if (_channel != null) {
      await disconnect();
    }

    final wsBaseUrl = baseUrl
        .replaceFirst('http', 'ws')
        .replaceFirst('https', 'wss');
    final cleanBaseUrl = wsBaseUrl.endsWith('/')
        ? wsBaseUrl.substring(0, wsBaseUrl.length - 1)
        : wsBaseUrl;
    final cleanWsPath = wsPath.startsWith('/') ? wsPath : '/$wsPath';
    final uri = Uri.parse('$cleanBaseUrl$cleanWsPath').replace(
      queryParameters: {'access_token': token},
    );

    try {
      _accessToken = token;
      _shouldReconnect = true;
      _channel = WebSocketChannel.connect(uri);

      _channel!.stream.listen(
        (message) {
          if (message is! String) return;
          try {
            final data = jsonDecode(message) as Map<String, dynamic>;
            _eventController.add(data);
          } catch (e) {
            // Ignore malformed messages
          }
        },
        onDone: _handleDisconnect,
        onError: (Object error, StackTrace stackTrace) =>
            _handleDisconnect(error),
      );
    } catch (e) {
      _handleDisconnect(e);
    }
  }

  void _handleDisconnect([Object? error]) {
    if (_isDisposed) return;

    if (_isAuthError(error)) {
      _shouldReconnect = false;
      _accessToken = null;
    }

    _channel = null;
    if (!_shouldReconnect || _accessToken == null) return;

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      final token = _accessToken;
      if (token != null && !_isDisposed) {
        connect(token: token);
      }
    });
  }

  bool _isAuthError(Object? error) {
    final text = error?.toString().toLowerCase() ?? '';
    return text.contains('401') ||
        text.contains('unauthorized') ||
        text.contains('not upgraded to websocket');
  }

  Future<void> disconnect() async {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _accessToken = null;
    final channel = _channel;
    _channel = null;
    await channel?.sink.close();
  }

  /// Sends a control message using the backend's nested payload shape.
  void _send(String type, Map<String, dynamic> data) {
    if (_channel == null) return;
    _channel!.sink.add(jsonEncode({'type': type, 'data': data}));
  }

  /// Accept an offered ride (driver). Requires a live /ws connection.
  void acceptOffer(String rideId) => _send('ride.accept', {'ride_id': rideId});

  /// Decline an offered ride (driver). The HTTP decline endpoint is a STUB, so
  /// this WS message is the only supported decline path.
  void declineOffer(String rideId) =>
      _send('ride.decline', {'ride_id': rideId});

  /// Keep-alive heartbeat; the backend replies `{"type":"pong"}`.
  void ping() => _send('ping', {});

  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _channel?.sink.close();
    _eventController.close();
  }
}