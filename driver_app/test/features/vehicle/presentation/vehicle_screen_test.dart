/// The vehicle section's first suite — driver bug #3.
///
/// `/vehicle` is a first-class drawer + profile-card destination (bug #6), but
/// its details/save half stays gated on `vehicleFeatureEnabled` while
/// `GET/PUT /driver/me/vehicle` and `GET/POST /driver/me/documents` are backend
/// stubs (`internal/router/router.go:219-222`). These tests pin the decoupling:
/// the nav entry is unconditional, the screen honours the gate, and no write
/// request ever leaves the device.
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/config.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/features/vehicle/presentation/vehicle_screen.dart';

/// Records what the screen actually asked the server for.
class RequestLog {
  final List<String> requests = <String>[];

  void attach(Dio dio) {
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests.add('${options.method} ${options.path}');
          handler.next(options);
        },
      ),
    );
  }
}

void main() {
  late ApiClient apiClient;
  late DioAdapter dioAdapter;
  late RequestLog log;

  setUp(() {
    apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    dioAdapter = DioAdapter(
      dio: apiClient.dio,
      matcher: const UrlRequestMatcher(matchMethod: true),
    );
    log = RequestLog()..attach(apiClient.dio);
  });

  /// Pumps the body-only screen the way `DriverShell` hosts it. [settle]
  /// defaults to true; the loading case passes `false` so the in-flight frame
  /// can be observed (a spinner never settles).
  Future<void> pumpVehicle(
    WidgetTester tester, {
    required bool enabled,
    bool settle = true,
  }) async {
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(apiClient),
        vehicleFeatureEnabledProvider.overrideWithValue(enabled),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: VehicleScreen())),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // Dio wraps every interceptor step in a zero-duration `Timer`, which a
      // bare `pump()` (microtasks only) never fires.
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  void serveVehicle(Map<String, dynamic> body) {
    dioAdapter.onGet(
      ApiEndpoints.driverMeVehicle,
      (server) => server.reply(200, body),
    );
  }

  group('the shipped gate', () {
    test('keeps the details/save surface off while the backend is a stub', () {
      // The gating decision this plan implements: the nav entry is
      // unconditional, the *saving* surface stays off until
      // `GET/PUT /driver/me/vehicle` and `GET/POST /driver/me/documents` ship
      // (the authoritative skip list in driver_app_plans/STATUS.md). Flipping
      // this const is a backend-driven step that must also revisit the
      // "Coming soon" expectations below.
      expect(ApiConfig.vehicleFeatureEnabled, isFalse);
    });
  });

  group('flag off (the shipped default)', () {
    testWidgets('renders the Coming soon disclosure and reads nothing', (
      tester,
    ) async {
      await pumpVehicle(tester, enabled: false);

      expect(find.text('Coming soon'), findsOneWidget);
      expect(
        find.textContaining(
          'Vehicle & documents verification is handled by the admin team.',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.construction), findsOneWidget);
      // The gated branch is not a dead end behind a spinner, and it never
      // touches the stub endpoint.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(log.requests, isEmpty);
    });
  });

  group('flag on (overridden)', () {
    testWidgets('GETs /driver/me/vehicle and renders status + message', (
      tester,
    ) async {
      serveVehicle({
        'status': 'verified',
        'message': 'Toyota Prius / plate ABC-123',
      });

      await pumpVehicle(tester, enabled: true);

      expect(find.text('verified'), findsOneWidget);
      expect(find.text('Toyota Prius / plate ABC-123'), findsOneWidget);
      // Exactly one request, and it is a GET: the details branch is read-only
      // while the backend endpoints are stubs.
      expect(log.requests, ['GET ${ApiEndpoints.driverMeVehicle}']);
      expect(
        find.textContaining('nothing can be saved here yet'),
        findsOneWidget,
      );
    });

    testWidgets('shows the loading state while the read is in flight', (
      tester,
    ) async {
      final gate = Completer<void>();
      dioAdapter.onGet(
        ApiEndpoints.driverMeVehicle,
        (server) => server.replyCallbackAsync(200, (options) async {
          await gate.future;
          return {'status': 'verified'};
        }),
      );

      await pumpVehicle(tester, enabled: true, settle: false);

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Coming soon'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.text('verified'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(log.requests, ['GET ${ApiEndpoints.driverMeVehicle}']);
    });

    testWidgets('a failed read surfaces the error state', (tester) async {
      dioAdapter.onGet(
        ApiEndpoints.driverMeVehicle,
        (server) => server.reply(500, {
          'error': {'code': 'INTERNAL', 'message': 'boom'},
        }),
      );

      await pumpVehicle(tester, enabled: true);

      expect(
        find.text('Could not load vehicle details. Please try again.'),
        findsOneWidget,
      );
      // The failure path is still read-only.
      expect(log.requests, ['GET ${ApiEndpoints.driverMeVehicle}']);
    });
  });

  testWidgets('neither branch ever issues a write request', (tester) async {
    // The authoritative gate: no UI is built on the `PUT /driver/me/vehicle`
    // or `POST /driver/me/documents` stubs. Exercised across both branches.
    serveVehicle({'status': 'verified'});

    await pumpVehicle(tester, enabled: false);
    await pumpVehicle(tester, enabled: true);

    expect(log.requests, ['GET ${ApiEndpoints.driverMeVehicle}']);
    expect(
      log.requests.every((r) => r.startsWith('GET ')),
      isTrue,
      reason: 'the vehicle screen is read-only while the endpoints are stubs',
    );
    expect(
      log.requests.where((r) => r.contains('/documents')),
      isEmpty,
    );
  });
}
