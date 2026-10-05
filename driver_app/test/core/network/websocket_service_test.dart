import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';

Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  late HttpServer server;
  late int port;
  late List<WebSocket> sockets;
  late List<Map<String, dynamic>> received;
  late List<DriverWebSocketService> shims;

  int pingCount() => received.where((m) => m['type'] == 'ping').length;

  DriverWebSocketService startService({
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) {
    final shim = DriverWebSocketService(
      WebSocketService(
        baseUrl: 'http://127.0.0.1:$port',
        wsPath: '/ws',
        heartbeatInterval: heartbeatInterval,
      ),
    );
    shims.add(shim);
    return shim;
  }

  setUp(() async {
    sockets = <WebSocket>[];
    received = <Map<String, dynamic>>[];
    shims = <DriverWebSocketService>[];
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
    for (final shim in shims) {
      await shim.disconnect();
    }
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  });

  test('driver sends the nested wire format for accept/decline/ping', () async {
    final shim = startService();
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    shim.acceptOffer('r1');
    await waitFor(() => received.any((m) => m['type'] == 'ride.accept'));
    shim.declineOffer('r2');
    await waitFor(() => received.any((m) => m['type'] == 'ride.decline'));
    shim.ping();
    await waitFor(() => received.any((m) => m['type'] == 'ping'));

    final accept = received.firstWhere((m) => m['type'] == 'ride.accept');
    final decline = received.firstWhere((m) => m['type'] == 'ride.decline');
    final ping = received.firstWhere((m) => m['type'] == 'ping');

    expect(accept, {'type': 'ride.accept', 'data': {'ride_id': 'r1'}});
    expect(accept['ride_id'], isNull,
        reason: 'flat ride_id payloads are broken - the hub reads data.ride_id');
    expect(decline, {'type': 'ride.decline', 'data': {'ride_id': 'r2'}});
    expect(ping, {'type': 'ping', 'data': <String, dynamic>{}});
  });

  test('broadcast messages decode into typed WsEvents', () async {
    final shim = startService();
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final emitted = <WsEvent>[];
    final sub = shim.events.listen(emitted.add);
    addTearDown(() => sub.cancel());

    final socket = sockets.first;
    socket.add(jsonEncode({'type': 'ride.offer', 'data': {'ride_id': 'r1'}}));
    socket.add(jsonEncode({
      'type': 'ride.updated',
      'data': {'id': 'r1', 'rider_id': 'u1', 'status': 'accepted'},
    }));
    socket.add(jsonEncode({
      'type': 'driver.location',
      'data': {'lat': 9.93, 'lng': -84.08},
    }));
    socket.add(jsonEncode({'type': 'pong', 'data': {}}));

    await waitFor(() => emitted.length >= 4);

    expect(emitted[0].type, WsEventType.offer);
    expect(emitted[0].data, {'ride_id': 'r1'});
    expect(emitted[1].type, WsEventType.updated);
    expect(emitted[1].data['id'], 'r1');
    expect(emitted[1].data['status'], 'accepted');
    expect(emitted[2].type, WsEventType.location);
    expect(emitted[3].type, WsEventType.other);
  });

  test(
    'reconnects with a fresh connection after the socket dies',
    () async {
      final shim = startService();
      await shim.connect(token: 'driver-token');
      await waitFor(() => sockets.isNotEmpty);

      await sockets.first.close();
      await waitFor(
        () => sockets.length >= 2,
        timeout: const Duration(seconds: 10),
      );
      expect(sockets.length, 2);
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test('heartbeat pings on an interval while the driver is connected',
      () async {
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    shim.setOnline(true);

    await waitFor(
      () => received.where((m) => m['type'] == 'ping').length >= 3,
    );

    expect(
      received.where((m) => m['type'] == 'ping').length,
      greaterThanOrEqualTo(3),
      reason: 'an idle driver socket must keep itself alive with pings',
    );
  });

  test('heartbeat stops when the driver goes offline and re-arms when online',
      () async {
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    shim.setOnline(true);
    await waitFor(
      () => received.where((m) => m['type'] == 'ping').length >= 2,
    );

    shim.setOnline(false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final offlineCount = received.where((m) => m['type'] == 'ping').length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(
      received.where((m) => m['type'] == 'ping').length,
      offlineCount,
      reason: 'an offline driver must not keep pinging',
    );

    shim.setOnline(true);
    await waitFor(
      () => received.where((m) => m['type'] == 'ping').length > offlineCount,
    );
  });

  test('repeated setOnline does not stack heartbeat timers', () async {
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 50),
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);

    // Each setOnline(true) pings once immediately (by design); the burst below
    // is expected. What must not happen is ten live periodics afterwards.
    for (var i = 0; i < 10; i++) {
      shim.setOnline(true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final before = pingCount();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final extra = pingCount() - before;

    expect(extra, greaterThanOrEqualTo(2),
        reason: 'the heartbeat must keep running after repeated setOnline');
    expect(extra, lessThanOrEqualTo(20),
        reason: 'repeated setOnline must not multiply the interval timer');
  });

  test('a reconnected driver re-publishes and pings again', () async {
    final shim = startService();
    var reconnectCount = 0;
    shim.onReconnected = () => reconnectCount++;
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    await waitFor(() => reconnectCount >= 1);
    shim.setOnline(true);
    await waitFor(() => pingCount() >= 1,
        timeout: const Duration(seconds: 5));
    final pingsBeforeReconnect = pingCount();

    await sockets.first.close();
    await waitFor(
      () => sockets.length >= 2,
      timeout: const Duration(seconds: 10),
    );
    await waitFor(
      () => reconnectCount >= 2,
      timeout: const Duration(seconds: 10),
    );
    // Work item 2 of the plan: a fresh connection must re-send ping, not just
    // re-publish, or the driver waits a whole heartbeat (25 s) to be visible.
    await waitFor(
      () => pingCount() > pingsBeforeReconnect,
      timeout: const Duration(seconds: 10),
    );

    expect(
      reconnectCount,
      greaterThanOrEqualTo(2),
      reason: 're-publish + immediate ping must fire on reconnect too',
    );
    expect(
      pingCount(),
      greaterThan(pingsBeforeReconnect),
      reason: 'a reconnect must send an immediate ping on the new socket',
    );
    expect(shim.isConnected, isTrue);
  }, timeout: const Timeout(Duration(seconds: 25)));

  test('a reconnect while offline does not restart the heartbeat', () async {
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    shim.setOnline(false);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final offlineCount = received.where((m) => m['type'] == 'ping').length;

    await sockets.first.close();
    await waitFor(
      () => sockets.length >= 2,
      timeout: const Duration(seconds: 10),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(
      received.where((m) => m['type'] == 'ping').length,
      offlineCount,
      reason: 'an offline driver stays offline across a reconnect',
    );
  }, timeout: const Timeout(Duration(seconds: 25)));
}
