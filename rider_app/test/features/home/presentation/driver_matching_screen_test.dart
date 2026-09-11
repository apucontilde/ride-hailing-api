import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/data/ride_status_provider.dart';
import 'package:rider_app/features/home/presentation/driver_matching_screen.dart';

class FakeWebSocketService extends WebSocketService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;

  void emit(Map<String, dynamic> event) => _controller.add(event);

  void disposeController() => _controller.close();
}

void main() {
  late FakeWebSocketService ws;
  late RideStatusNotifier rideNotifier;
  late ApiClient apiClient;
  late DioAdapter dioAdapter;

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

  Widget buildRouter() {
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
    return ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(apiClient),
        rideStatusProvider.overrideWith((ref) => rideNotifier),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('shows finding driver animation', (WidgetTester tester) async {
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {'ride': {'id': 'ride-1', 'status': 'pending'}}),
    );

    await tester.pumpWidget(buildRouter());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text('Finding your driver...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancel button hits the cancel endpoint and returns home',
      (WidgetTester tester) async {
    dioAdapter.onGet(
      '/api/v1/rides/current',
      (server) => server.reply(200, {'ride': {'id': 'ride-1', 'status': 'pending'}}),
    );
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.reply(200, {'ride': {'id': 'ride-1', 'status': 'cancelled'}}),
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

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('no drivers state appears when poll returns no_driver_available',
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
  });

  testWidgets('no drivers toast appears once when the poll flags it',
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

    expect(find.text('No drivers found right now. Please try again.'),
        findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  });
}