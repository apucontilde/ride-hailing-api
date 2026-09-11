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
import 'package:rider_app/features/home/presentation/active_ride_screen.dart';

class FakeWebSocketService extends WebSocketService {
  final StreamController<Map<String, dynamic>> _controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;

  void emit(Map<String, dynamic> event) => _controller.add(event);

  void disposeController() => _controller.close();
}

Map<String, dynamic> acceptedEvent() => {
      'type': 'ride.updated',
      'data': {
        'ride_id': 'ride-1',
        'status': 'accepted',
        'eta_seconds': 300,
        'driver': {
          'id': 'driver-1',
          'first_name': 'Maria',
          'photo_url': 'https://example.com/maria.jpg',
          'rating': 4.9,
          'vehicle': {
            'make': 'Toyota',
            'model': 'Corolla',
            'color': 'White',
            'plate_number': 'AB123CD',
          },
          'location': {'lat': 9.93, 'lng': -84.09, 'heading': 90},
        },
        'pickup': {'lat': 9.9281, 'lng': -84.0907, 'address': 'Main St'},
        'dropoff': {'lat': 9.94, 'lng': -84.10, 'address': 'Airport Rd'},
      },
    };

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

  void emit(Map<String, dynamic> event) => ws.emit(event);

  Widget buildRouter() {
    final router = GoRouter(
      initialLocation: '/active-ride',
      routes: [
        GoRoute(
          path: '/active-ride',
          builder: (context, state) => const ActiveRideScreen(),
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

  testWidgets('accepting a ride shows the active ride screen',
      (WidgetTester tester) async {
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    expect(find.text('Cancel Ride'), findsOneWidget);
    expect(find.text('Driver Approaching'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('pressed cancel shows confirmation and posts the cancel request',
      (WidgetTester tester) async {
    dioAdapter.onPost(
      '/api/v1/rides/ride-1/cancel',
      (server) => server.reply(200, {'ride': {'id': 'ride-1', 'status': 'cancelled'}}),
    );
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();

    expect(find.text('Cancel this ride?'), findsOneWidget);

    await tester.tap(find.text('Yes, Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();

    expect(find.text('Ride cancelled successfully'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('cancel confirmation negative keeps the ride active',
      (WidgetTester tester) async {
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    await tester.tap(find.text('Cancel Ride'));
    await tester.pump();

    await tester.tap(find.text('Keep Ride'));
    await tester.pump();

    expect(find.text('Cancel Ride'), findsOneWidget);
    expect(find.text('Home'), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('WS cancelled event routes home', (WidgetTester tester) async {
    emit(acceptedEvent());

    await tester.pumpWidget(buildRouter());
    await tester.pump();

    emit({
      'type': 'ride.updated',
      'data': {'ride_id': 'ride-1', 'status': 'cancelled', 'cancelled_by': 'driver'},
    });
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 1));
  });
}