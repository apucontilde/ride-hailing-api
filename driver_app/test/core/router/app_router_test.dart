import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/app_bootstrap.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/core/router/app_router.dart';
import 'package:driver_app/features/auth/presentation/login_screen.dart';
import 'package:driver_app/features/trip/presentation/trip_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockWebSocketService extends Mock implements WebSocketService {}

/// The session bootstrap seam: with an empty session the router must settle on
/// `/login`; with a persisted driver session and a live trip it must restore the
/// trip. Before the bootstrap resolves, a deep link is held on `/splash` and
/// never bounces to `/login`.
void main() {
  ProviderContainer buildContainer({
    bool withSession = false,
    bool withRide = false,
    bool canLogin = false,
  }) {
    final storage = MockAuthStorage();
    when(() => storage.getRememberedEmail()).thenAnswer((_) async => null);
    when(() => storage.saveRememberedEmail(any())).thenAnswer((_) async {});
    when(() => storage.clearTokens()).thenAnswer((_) async {});
    when(() => storage.saveTokens(
          accessToken: any(named: 'accessToken'),
          refreshToken: any(named: 'refreshToken'),
        )).thenAnswer((_) async {});

    final apiClient = MockApiClient();
    final dio = MockDio();
    when(() => apiClient.dio).thenReturn(dio);
    final ws = MockWebSocketService();
    when(() => ws.connect(token: any(named: 'token'))).thenAnswer((_) async {});
    when(() => ws.disconnect()).thenAnswer((_) async {});
    when(() => ws.events)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());

    if (withSession || canLogin) {
      when(() => dio.get(ApiEndpoints.driverMe)).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
          statusCode: 200,
          data: {
            'driver': {
              'user_id': 'd1',
              'first_name': 'Ada',
              'last_name': 'Lovelace',
              'status': 'offline',
            },
          },
        ),
      );
    }
    if (withSession) {
      when(() => storage.getAccessToken()).thenAnswer((_) async => 'access');
      when(() => storage.getRefreshToken()).thenAnswer((_) async => 'refresh');
    } else {
      when(() => storage.getAccessToken()).thenAnswer((_) async => null);
      when(() => storage.getRefreshToken()).thenAnswer((_) async => null);
    }

    when(() => dio.post(ApiEndpoints.login, data: any(named: 'data')))
        .thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.login),
        statusCode: 200,
        data: {
          'access_token': 'access',
          'refresh_token': 'refresh',
          'user': {'id': 'd1', 'email': 'ada@example.com', 'role': 'driver'},
        },
      ),
    );

    when(() => dio.get(ApiEndpoints.driverRidesCurrent)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverRidesCurrent),
        statusCode: 200,
        data: withRide
            ? {
                'ride': {
                  'id': 'r9',
                  'rider_id': 'u1',
                  'status': 'in_progress',
                  'pickup_lat': 9.93,
                  'pickup_lng': -84.08,
                  'dropoff_lat': 9.95,
                  'dropoff_lng': -84.1,
                },
              }
            : {'ride': null},
      ),
    );

    final container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(storage),
        apiClientProvider.overrideWithValue(apiClient),
        webSocketServiceProvider.overrideWithValue(ws),
        // No tiles: the map must not touch the network under flutter_test.
        mapTileLayerProvider.overrideWith((ref, config) => null),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: container.read(routerProvider),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an unresolved bootstrap holds a deep link on /splash',
      (tester) async {
    final container = buildContainer();
    await pumpApp(tester, container);

    container.read(routerProvider).go('/trip');
    await tester.pump();

    // Never the transient default `unauthenticated` → /login.
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a settled empty session lands on /login', (tester) async {
    final container = buildContainer();
    await pumpApp(tester, container);

    await container.read(sessionBootstrapProvider).run();
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('a reload parked on /home with a live trip restores onto /trip',
      (tester) async {
    final container = buildContainer(withSession: true, withRide: true);
    await pumpApp(tester, container);

    // A hash reload parked on a shell section.
    container.read(routerProvider).go('/home');
    await tester.pump();
    expect(find.byType(LoginScreen), findsNothing);

    await container.read(sessionBootstrapProvider).run();
    await tester.pumpAndSettle();

    expect(container.read(rideStateProvider).currentRide!.id, 'r9');
    expect(find.byType(TripScreen), findsOneWidget);
    expect(find.text('No active trip'), findsNothing);
  });

  testWidgets(
      'a driver who logs in with a live trip is restored onto /trip '
      '(launch logged-out → login)', (tester) async {
    // The bootstrap completes on /login with no session. Login happens *after*
    // `run()`, so `run()` cannot be the restore trigger — the auth listener in
    // `sessionBootstrapProvider` must re-run the current-ride restore. Before
    // the fix the one-shot latch was set while unauthenticated and this path
    // showed Home with a live server-side ride.
    final container = buildContainer(withRide: true, canLogin: true);
    await pumpApp(tester, container);

    await container.read(sessionBootstrapProvider).run();
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);

    await container.read(authProvider.notifier).login('ada@example.com', 'pw');
    await tester.pumpAndSettle();

    expect(container.read(rideStateProvider).currentRide!.id, 'r9');
    expect(find.byType(TripScreen), findsOneWidget);
    expect(find.text('No active trip'), findsNothing);
  });
}
