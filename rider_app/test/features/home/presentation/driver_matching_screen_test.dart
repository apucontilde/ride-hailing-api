import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/features/home/data/current_ride_provider.dart';
import 'package:rider_app/features/home/data/location_ping_service.dart';
import 'package:rider_app/features/home/data/pickup_memory_provider.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';
import 'package:rider_app/features/home/presentation/driver_matching_screen.dart';

import '../../../support/fake_websocket_service.dart';

/// Records only the lifecycle the screen drives; the service's own throttling
/// and lease accounting live in `location_ping_service_test.dart`.
class FakeLocationPingService extends LocationPingService {
  FakeLocationPingService(super.apiClient);

  int startCount = 0;
  int stopCount = 0;
  bool _active = false;

  @override
  void start() {
    startCount++;
    _active = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _active = false;
  }

  @override
  bool get isActive => _active;
}

/// A poll notifier whose state a test can drive without waiting for the real
/// 60-attempt cap. `startPolling` is the screen's retry path: it clears the
/// timeout flag and returns to the searching state.
class FakeCurrentRideNotifier extends CurrentRideNotifier {
  FakeCurrentRideNotifier(super.apiClient, super.ref);

  int startPollingCalls = 0;

  @override
  void startPolling({Duration interval = const Duration(seconds: 5)}) {
    startPollingCalls++;
    // Exercise the production restart (reset + a real `/rides/current` poll)
    // instead of only flipping test state.
    super.startPolling(interval: interval);
  }

  void forceTimedOut() {
    state = const CurrentRideState(status: 'pending', searchTimedOut: true);
  }
}

void main() {
  late FakeWebSocketService ws;
  late RideStatusNotifier rideNotifier;
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late ProviderContainer container;
  FakeCurrentRideNotifier? fakeRidePoll;

  setUp(() {
    ws = FakeWebSocketService();
    rideNotifier = RideStatusNotifier(ws);
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(dio: apiClient.dio);
  });

  tearDown(() {
    ws.disposeController();
  });

  Future<void> makeMatching(WidgetTester tester) async {
    ws.emit({
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'pending'},
    });
    await tester.pump();
    await tester.pump();
  }

  Widget buildRouter({
    FakeLocationPingService? ping,
    bool withFakeRidePoll = false,
  }) {
    final router = GoRouter(
      initialLocation: '/driver-matching',
      routes: [
        GoRoute(
          path: '/driver-matching',
          builder: (context, state) => const DriverMatchingScreen(),
        ),
        GoRoute(
          path: '/home',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('Home'))),
        ),
      ],
    );
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(apiClient),
        rideStatusProvider.overrideWith((ref) => rideNotifier),
        if (withFakeRidePoll)
          currentRideProvider.overrideWith((ref) {
            final fake = FakeCurrentRideNotifier(apiClient, ref);
            fakeRidePoll = fake;
            return fake;
          }),
        if (ping != null) locationPingServiceProvider.overrideWithValue(ping),
      ],
    );
    addTearDown(container.dispose);
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('shows finding driver animation', (WidgetTester tester) async {
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'pending'},
      }),
    );

    await tester.pumpWidget(buildRouter());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text('Finding your driver...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancel button hits the cancel endpoint and returns home', (
    WidgetTester tester,
  ) async {
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'pending'},
      }),
    );
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'cancelled'},
      }),
    );
    await makeMatching(tester);

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await tester.tap(find.text('Cancel request'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(find.text('Ride cancelled successfully'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    // A cancel keeps the pickup for an immediate retry.
    expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'a second cancel tap while the cancel POST is in flight posts once',
    (WidgetTester tester) async {
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.reply(200, {
          'ride': {'id': 'ride-1', 'status': 'pending'},
        }),
      );
      final gate = Completer<void>();
      var cancelPosts = 0;
      dioAdapter.onPost(
        '/api/v1/rides/ride-1/cancel',
        (server) => server.replyCallbackAsync(200, (_) async {
          cancelPosts++;
          await gate.future;
          return {
            'ride': {'id': 'ride-1', 'status': 'cancelled'},
          };
        }),
      );
      await makeMatching(tester);

      await tester.pumpWidget(buildRouter());
      await tester.pump();

      // First tap starts the POST and parks it on `gate`.
      await tester.tap(find.text('Cancel request'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(cancelPosts, 1);

      // Second tap while the request is in flight must be dropped by the existing
      // `_cancelInFlight` early return.
      await tester.tap(find.text('Cancel request'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(cancelPosts, 1, reason: 'the second tap must not post again');

      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pump();

      expect(cancelPosts, 1);
      expect(find.text('Home'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('no-driver Back to Home keeps the pickup for a retry', (
    WidgetTester tester,
  ) async {
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'no_driver_available'},
      }),
    );
    await makeMatching(tester);

    await tester.pumpWidget(buildRouter());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    await tester.tap(find.text('Back to Home'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text('Home'), findsOneWidget);
    expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'the leading AppBackButton replaces Icons.close and routes through the no-driver home path',
    (WidgetTester tester) async {
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.reply(200, {
          'ride': {'id': 'ride-1', 'status': 'no_driver_available'},
        }),
      );
      await makeMatching(tester);

      await tester.pumpWidget(buildRouter());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tap(find.byType(AppBackButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Home'), findsOneWidget);
      expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets(
    'no drivers state appears when poll returns no_driver_available',
    (WidgetTester tester) async {
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.reply(200, {
          'ride': {'id': 'ride-1', 'status': 'no_driver_available'},
        }),
      );
      await makeMatching(tester);

      await tester.pumpWidget(buildRouter());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('No drivers found'), findsOneWidget);
      expect(find.text('Back to Home'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('no drivers toast appears once when the poll flags it', (
    WidgetTester tester,
  ) async {
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'no_driver_available'},
      }),
    );
    await makeMatching(tester);

    await tester.pumpWidget(buildRouter());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(
      find.text('No drivers found right now. Please try again.'),
      findsOneWidget,
    );

    // The same no-driver signal arriving again (twice) must not stack two
    // toasts: the messenger renders exactly one at a time.
    for (var i = 0; i < 2; i++) {
      ws.emit({
        'type': 'ride.updated',
        'data': {'ride_id': 'ride-1', 'status': 'no_driver_available'},
      });
    }
    await tester.pump();
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.text('No drivers found right now. Please try again.'),
      findsOneWidget,
    );

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'a timed-out poll renders the terminal view and Try again retries',
    (WidgetTester tester) async {
      var polls = 0;
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.replyCallback(200, (_) {
          polls++;
          return {
            'ride': {'id': 'ride-1', 'status': 'pending'},
          };
        }),
      );

      await tester.pumpWidget(buildRouter(withFakeRidePoll: true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.text('Finding your driver...'), findsOneWidget);
      final fake = fakeRidePoll!;
      expect(fake.startPollingCalls, 1);
      expect(polls, 1);

      fake.forceTimedOut();
      await tester.pump();

      expect(find.text('Search timed out'), findsOneWidget);
      expect(find.textContaining("couldn't confirm a driver"), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));

      // The real notifier restart clears the flag and polls the endpoint again.
      expect(fake.startPollingCalls, 2);
      expect(polls, 2);
      expect(container.read(currentRideProvider).searchTimedOut, isFalse);
      expect(find.text('Search timed out'), findsNothing);
      expect(find.text('Finding your driver...'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
    },
  );

  testWidgets('Cancel request from the timeout view cancels and returns home', (
    WidgetTester tester,
  ) async {
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'cancelled'},
      }),
    );
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {
        'ride': {'id': 'ride-1', 'status': 'pending'},
      }),
    );
    await makeMatching(tester);

    await tester.pumpWidget(buildRouter(withFakeRidePoll: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    fakeRidePoll!.forceTimedOut();
    await tester.pump();
    expect(find.text('Search timed out'), findsOneWidget);

    await tester.tap(find.text('Cancel request'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(find.text('Ride cancelled successfully'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(container.read(pickupMemoryProvider).restoreOnHome, isTrue);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'holds the location ping lease through matching and releases it on dispose',
    (WidgetTester tester) async {
      dioAdapter.onGet(
        '/api/v1/rides/current',
        (server) => server.reply(200, {
          'ride': {'id': 'ride-1', 'status': 'pending'},
        }),
      );
      final ping = FakeLocationPingService(apiClient);

      await tester.pumpWidget(buildRouter(ping: ping));
      await tester.pump();

      // Home was disposed by the `context.go` into matching; matching must keep
      // the rider position flowing until a driver accepts.
      expect(ping.startCount, 1);
      expect(ping.isActive, isTrue);

      // Let the first `/rides/current` poll settle before tearing the tree
      // down, so the notifier is not written after its container is disposed.
      await tester.pump(const Duration(milliseconds: 10));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));

      expect(ping.stopCount, 1);
      expect(ping.isActive, isFalse);
    },
  );
}
