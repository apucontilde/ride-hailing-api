import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';

/// A deterministic stand-in for [Timer], driven through the shared
/// `WebSocketTimerFactory` seam: nothing fires on its own; a test calls [fire].
///
/// `fakeAsync` cannot drive this suite: the service talks to a real `dart:io`
/// [WebSocket], and real I/O never completes inside a fake-clock zone (the
/// connect future is left pending). The timer seam is the appropriate
/// determinism mechanism here — the sleep/interval races are gone while the
/// real socket stays real.
class _ManualTimer implements Timer {
  _ManualTimer(this._callback, {required this.periodic});

  final void Function() _callback;
  final bool periodic;

  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  /// Fires the callback once if the timer is live. A one-shot timer consumes
  /// itself after firing, exactly like a real one.
  void fire() {
    if (!_active) return;
    _tick++;
    if (!periodic) _active = false;
    _callback();
  }
}

/// Records every timer the service creates so a test can drive one explicitly.
class _ManualTimers {
  final List<({Duration duration, _ManualTimer timer})> all =
      <({Duration duration, _ManualTimer timer})>[];

  Timer create(
    Duration duration,
    void Function() callback, {
    required bool periodic,
  }) {
    final timer = _ManualTimer(callback, periodic: periodic);
    all.add((duration: duration, timer: timer));
    return timer;
  }

  _ManualTimer? get activePeriodic => _activeLast(periodic: true);

  _ManualTimer? get activeOneShot => _activeLast(periodic: false);

  int get activePeriodicCount =>
      all.where((e) => e.timer.periodic && e.timer.isActive).length;

  _ManualTimer? _activeLast({required bool periodic}) {
    for (final entry in all.reversed) {
      if (entry.timer.periodic == periodic && entry.timer.isActive) {
        return entry.timer;
      }
    }
    return null;
  }
}

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
    _ManualTimers? timers,
  }) {
    final shim = DriverWebSocketService(
      WebSocketService(
        baseUrl: 'http://127.0.0.1:$port',
        wsPath: '/ws',
        heartbeatInterval: heartbeatInterval,
        timerFactory: timers?.create,
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
    final timers = _ManualTimers();
    final shim = startService(timers: timers);
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);

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
    final timers = _ManualTimers();
    final shim = startService(timers: timers);
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);

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
      final timers = _ManualTimers();
      final shim = startService(timers: timers);
      await shim.connect(token: 'driver-token');
      await waitFor(() => sockets.isNotEmpty);

      await sockets.first.close();
      // The reconnect delay is owned by the service and exposed through the
      // timer seam, so fire it deterministically instead of waiting 5 s.
      await waitFor(() => timers.activeOneShot != null);
      timers.activeOneShot!.fire();
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
    final timers = _ManualTimers();
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    shim.setOnline(true);

    final heartbeat = timers.activePeriodic;
    expect(heartbeat, isNotNull);
    for (var i = 0; i < 3; i++) {
      heartbeat!.fire();
      await waitFor(() => pingCount() >= i + 1);
    }

    expect(
      pingCount(),
      greaterThanOrEqualTo(3),
      reason: 'an idle driver socket must keep itself alive with pings',
    );
  });

  test('heartbeat stops when the driver goes offline and re-arms when online',
      () async {
    final timers = _ManualTimers();
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    shim.setOnline(true);
    final heartbeat = timers.activePeriodic!;
    heartbeat.fire();
    await waitFor(() => pingCount() >= 1);

    shim.setOnline(false);
    expect(timers.activePeriodicCount, 0,
        reason: 'going offline must cancel the keep-alive loop');
    final offlineCount = pingCount();
    heartbeat.fire();
    await pumpEventQueue();
    expect(
      pingCount(),
      offlineCount,
      reason: 'an offline driver must not keep pinging',
    );

    shim.setOnline(true);
    expect(timers.activePeriodicCount, 1,
        reason: 'going online must re-arm the keep-alive loop');
    timers.activePeriodic!.fire();
    await waitFor(() => pingCount() > offlineCount);
  });

  test('repeated setOnline does not stack heartbeat timers', () async {
    final timers = _ManualTimers();
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 50),
      timers: timers,
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);

    // Each setOnline(true) pings once immediately (by design); the burst below
    // is expected. What must not happen is ten live periodics afterwards.
    for (var i = 0; i < 10; i++) {
      shim.setOnline(true);
    }
    expect(timers.activePeriodicCount, 1,
        reason: 'repeated setOnline must not multiply the interval timer');

    // Let the ten immediate pings from the setOnline burst reach the server so
    // the next measurement isolates the single heartbeat tick.
    await waitFor(() => pingCount() >= 10);
    final before = pingCount();
    timers.activePeriodic!.fire();
    await waitFor(() => pingCount() > before);
    expect(pingCount() - before, 1,
        reason: 'exactly one live loop sends one ping per tick');
  });

  test('a reconnected driver re-publishes and pings again', () async {
    final timers = _ManualTimers();
    final shim = startService(timers: timers);
    var reconnectCount = 0;
    shim.onReconnected = () => reconnectCount++;
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    await waitFor(() => reconnectCount >= 1);
    shim.setOnline(true);
    await waitFor(() => pingCount() >= 1);
    final pingsBeforeReconnect = pingCount();

    await sockets.first.close();
    await waitFor(() => timers.activeOneShot != null);
    timers.activeOneShot!.fire();
    await waitFor(
      () => sockets.length >= 2,
      timeout: const Duration(seconds: 10),
    );
    await waitFor(
      () => reconnectCount >= 2,
      timeout: const Duration(seconds: 10),
    );
    // A fresh connection must re-send ping, not just re-publish, or the driver
    // waits a whole heartbeat (25 s) to be visible.
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
    final timers = _ManualTimers();
    final shim = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await shim.connect(token: 'driver-token');
    await waitFor(() => sockets.isNotEmpty);
    shim.setOnline(false);
    expect(timers.activePeriodicCount, 0);
    final offlineCount = received.where((m) => m['type'] == 'ping').length;

    await sockets.first.close();
    await waitFor(() => timers.activeOneShot != null);
    timers.activeOneShot!.fire();
    await waitFor(
      () => sockets.length >= 2,
      timeout: const Duration(seconds: 10),
    );
    await pumpEventQueue();

    expect(
      timers.activePeriodicCount,
      0,
      reason: 'an offline driver stays offline across a reconnect',
    );
    expect(
      received.where((m) => m['type'] == 'ping').length,
      offlineCount,
      reason: 'an offline driver stays offline across a reconnect',
    );
  }, timeout: const Timeout(Duration(seconds: 25)));
}
