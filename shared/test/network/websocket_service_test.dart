import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late HttpServer server;
  late int port;
  late List<WebSocket> sockets;
  late List<Map<String, dynamic>> received;
  late List<WebSocketService> services;

  WebSocketService startService({
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) {
    final service = WebSocketService(
      baseUrl: 'http://127.0.0.1:$port',
      wsPath: '/ws',
      heartbeatInterval: heartbeatInterval,
    );
    services.add(service);
    return service;
  }

  int pingCount() => received.where((m) => m['type'] == 'ping').length;

  setUp(() async {
    sockets = <WebSocket>[];
    received = <Map<String, dynamic>>[];
    services = <WebSocketService>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) return;
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((dynamic message) {
        if (message is! String) return;
        received.add(jsonDecode(message) as Map<String, dynamic>);
      });
    });
  });

  tearDown(() async {
    for (final service in services) {
      service.dispose();
    }
    await Future<void>.delayed(Duration.zero);
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  });

  test('heartbeat pings on the configured interval while connected', () async {
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);

    await waitFor(() => pingCount() >= 3);

    expect(pingCount(), greaterThanOrEqualTo(3),
        reason: 'the keep-alive must fire repeatedly, not just once');
    // The wire shape stays the nested one the hub expects.
    expect(received.firstWhere((m) => m['type'] == 'ping'),
        {'type': 'ping', 'data': <String, dynamic>{}});
  });

  test('startHeartbeat is idempotent and never stacks timers', () async {
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 50),
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);
    await waitFor(() => pingCount() >= 2);

    // Re-arm the loop many times, exactly as connect()/setOnline() do.
    for (var i = 0; i < 10; i++) {
      service.startHeartbeat();
    }

    final before = pingCount();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final extra = pingCount() - before;

    // A single 50 ms loop sends ~8 pings in a 400 ms window. Ten stacked
    // timers would send ~80; the upper bound fails loudly on stacking while
    // staying generous to scheduler jitter (a periodic timer cannot fire
    // faster than its interval, so ~9 is the real ceiling).
    expect(extra, greaterThanOrEqualTo(2),
        reason: 'the heartbeat must keep running after re-arming');
    expect(extra, lessThanOrEqualTo(20),
        reason: 'repeated startHeartbeat must not stack timers');
  });

  test('heartbeat stops on disconnect', () async {
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await service.connect(token: 'token');
    await waitFor(() => pingCount() >= 2);

    await service.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = pingCount();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(pingCount(), before,
        reason: 'no ping may be sent after disconnect');
  });

  test('heartbeat stops on dispose', () async {
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await service.connect(token: 'token');
    await waitFor(() => pingCount() >= 2);

    service.dispose();
    services.remove(service);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final before = pingCount();
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(pingCount(), before, reason: 'no ping may be sent after dispose');
  });

  test('stopHeartbeat halts the loop and startHeartbeat resumes it', () async {
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await service.connect(token: 'token');
    await waitFor(() => pingCount() >= 2);

    service.stopHeartbeat();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final paused = pingCount();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(pingCount(), paused, reason: 'a stopped heartbeat stays stopped');

    service.startHeartbeat();
    await waitFor(() => pingCount() > paused);
  });

  test('onConnected fires after every connect', () async {
    final service = startService();
    var connected = 0;
    service.onConnected = () => connected++;

    await service.connect(token: 'token');
    await waitFor(() => connected >= 1);

    expect(connected, 1);
  });
}
