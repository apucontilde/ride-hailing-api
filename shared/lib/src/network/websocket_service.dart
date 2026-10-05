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

  /// How often [ping] is sent while a socket is connected.
  ///
  /// The backend has no read deadline of its own, so the interval only has to
  /// detect a socket that died silently on a NAT/load-balancer idle timeout: a
  /// write to a dead socket surfaces through the channel's error handler, which
  /// tears the channel down and lets [connect] re-arm. It is also kept under the
  /// dispatch position window (30 s) so a ping-caused reconnect can re-publish
  /// before the driver ages out.
  ///
  /// **Disabled by default** ([Duration.zero]): the keep-alive is opt-in per
  /// app, so the rider does not pay for a driver-side reliability fix (and does
  /// not leave a pending timer in widget tests that never disconnect). The
  /// driver app enables it via its `webSocketServiceProvider`.
  final Duration heartbeatInterval;

  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  String? _accessToken;
  bool _shouldReconnect = false;
  bool _isDisposed = false;
  final StreamController<Map<String, dynamic>> _eventController =
      StreamController.broadcast();

  /// Invoked after every successful [connect] — the first connect and every
  /// automatic reconnect. The driver app uses this to re-publish its last
  /// position so a freshly-connected driver is immediately dispatchable; the
  /// shared service itself only guarantees the ping below.
  void Function()? onConnected;

  WebSocketService({
    String? baseUrl,
    this.wsPath = '/ws',
    this.heartbeatInterval = Duration.zero,
  }) : baseUrl = baseUrl ?? 'http://localhost:8080';

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Whether a socket is currently **open** — not whether it is **alive**.
  ///
  /// A socket that died silently (NAT/intermediary idle timeout) still reads
  /// `true` until a read or write actually fails. The [heartbeatInterval]
  /// ping is what keeps that window short; treat the heartbeat as the real
  /// liveness signal and this getter as "there is a channel object to write
  /// to". Used by the driver offer dialog to decide between the WS accept path
  /// and the HTTP fallback.
  bool get isConnected => _channel != null;

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
      // Keep the socket alive (and make a silent death discoverable) and let
      // the app react to every (re)connect.
      startHeartbeat();
      onConnected?.call();
    } catch (e) {
      _handleDisconnect(e);
    }
  }

  void _handleDisconnect([Object? error]) {
    if (_isDisposed) return;

    // The channel is gone; stop pinging it. `connect` re-arms the heartbeat on
    // every (re)connect.
    _stopHeartbeat();

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

  /// Starts (or restarts) the keep-alive ping loop for the current channel.
  ///
  /// Idempotent: an existing loop is cancelled first, so calling this from
  /// [connect] and from the driver's "went online" hook never stacks timers.
  /// No-op when disposed or when [heartbeatInterval] is [Duration.zero].
  void startHeartbeat() {
    if (_isDisposed) return;
    if (heartbeatInterval <= Duration.zero) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (_isDisposed || _channel == null) return;
      ping();
    });
  }

  /// Cancels the keep-alive ping loop. Safe to call more than once.
  void stopHeartbeat() => _stopHeartbeat();

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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
    _stopHeartbeat();
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
    _stopHeartbeat();
    _channel?.sink.close();
    _eventController.close();
  }
}