import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// A deterministic stand-in for [Timer], driven through the service's
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
    _ManualTimers? timers,
  }) {
    final service = WebSocketService(
      baseUrl: 'http://127.0.0.1:$port',
      wsPath: '/ws',
      heartbeatInterval: heartbeatInterval,
      timerFactory: timers?.create,
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
    final timers = _ManualTimers();
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);

    // The keep-alive is armed with the configured interval and fires repeatedly
    // (not just once) when the clock advances.
    final heartbeat = timers.activePeriodic;
    expect(heartbeat, isNotNull);
    expect(
      timers.all.singleWhere((e) => e.timer.periodic).duration,
      const Duration(milliseconds: 40),
      reason: 'the heartbeat must run on the configured interval',
    );

    for (var i = 0; i < 3; i++) {
      heartbeat!.fire();
      await waitFor(() => pingCount() >= i + 1);
    }

    expect(pingCount(), greaterThanOrEqualTo(3),
        reason: 'the keep-alive must fire repeatedly, not just once');
    // The wire shape stays the nested one the hub expects.
    expect(received.firstWhere((m) => m['type'] == 'ping'),
        {'type': 'ping', 'data': <String, dynamic>{}});
  });

  test('startHeartbeat is idempotent and never stacks timers', () async {
    final timers = _ManualTimers();
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 50),
      timers: timers,
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);

    // Re-arm the loop many times, exactly as connect()/setOnline() do.
    for (var i = 0; i < 10; i++) {
      service.startHeartbeat();
    }

    // Ten stacked timers would leave ten live loops; the seam must have
    // cancelled the previous one every time.
    expect(timers.activePeriodicCount, 1,
        reason: 'repeated startHeartbeat must not stack timers');

    final before = pingCount();
    timers.activePeriodic!.fire();
    await waitFor(() => pingCount() > before);
    expect(pingCount(), before + 1,
        reason: 'a single live loop sends exactly one ping per tick');
  });

  test('heartbeat stops on disconnect', () async {
    final timers = _ManualTimers();
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);
    final heartbeat = timers.activePeriodic!;
    heartbeat.fire();
    await waitFor(() => pingCount() >= 1);

    await service.disconnect();
    expect(timers.activePeriodicCount, 0,
        reason: 'disconnect must cancel the keep-alive loop');

    final before = pingCount();
    heartbeat.fire();
    await pumpEventQueue();

    expect(pingCount(), before,
        reason: 'no ping may be sent after disconnect');
  });

  test('heartbeat stops on dispose', () async {
    final timers = _ManualTimers();
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);
    final heartbeat = timers.activePeriodic!;
    heartbeat.fire();
    await waitFor(() => pingCount() >= 1);

    service.dispose();
    services.remove(service);
    expect(timers.activePeriodicCount, 0,
        reason: 'dispose must cancel the keep-alive loop');

    final before = pingCount();
    heartbeat.fire();
    await pumpEventQueue();

    expect(pingCount(), before, reason: 'no ping may be sent after dispose');
  });

  test('stopHeartbeat halts the loop and startHeartbeat resumes it', () async {
    final timers = _ManualTimers();
    final service = startService(
      heartbeatInterval: const Duration(milliseconds: 40),
      timers: timers,
    );
    await service.connect(token: 'token');
    await waitFor(() => sockets.isNotEmpty);
    final first = timers.activePeriodic!;
    first.fire();
    await waitFor(() => pingCount() >= 1);
    final paused = pingCount();

    service.stopHeartbeat();
    expect(timers.activePeriodicCount, 0, reason: 'stop must cancel the loop');
    first.fire();
    await pumpEventQueue();
    expect(pingCount(), paused, reason: 'a stopped heartbeat stays stopped');

    service.startHeartbeat();
    expect(timers.activePeriodicCount, 1, reason: 'start must re-arm the loop');
    timers.activePeriodic!.fire();
    await waitFor(() => pingCount() > paused);
  });

  test('onConnected fires after every connect', () async {
    final timers = _ManualTimers();
    final service = startService(timers: timers);
    var connected = 0;
    service.onConnected = () => connected++;

    await service.connect(token: 'token');
    await waitFor(() => connected >= 1);
    expect(connected, 1);

    // The contract is "every (re)connect", not just the first: the driver
    // re-publishes its position from this hook on each one.
    await service.disconnect();
    await service.connect(token: 'token');
    await waitFor(() => connected >= 2);

    expect(connected, 2);
  });
}
