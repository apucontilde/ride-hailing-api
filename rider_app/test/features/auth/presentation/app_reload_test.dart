import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/app.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/core/router/app_router.dart';
import 'package:rider_app/features/auth/presentation/login_screen.dart';
import 'package:rider_app/features/home/data/location_service.dart';
import 'package:rider_app/features/home/presentation/home_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}

class MockWebSocketService extends Mock implements WebSocketService {}

/// Closes rider bug **#31**: the web-reload bootstrap was covered only at the
/// unit level (`resolveRedirect`) and by cold-start/login integration. Nothing
/// mounted the real [RiderApp] **at a reloaded shell location** to prove a
/// stored session at `/home` lands on [HomeScreen] and never bounces to
/// [LoginScreen].
///
/// These tests boot the real router at `/home` via the additive
/// `routerInitialLocationProvider` seam — the widget-test substitute for a
/// browser reload. A *real* browser reload is UNVERIFIABLE in this WSL harness
/// and still needs a manual close (see the plan).
void main() {
  const riderMeData = {
    'user': {
      'id': 'user-1',
      'email': 'rider@example.com',
      'phone': '+5065551234',
      'role': 'rider',
      'status': 'active',
    },
    'rider': {
      'user_id': 'user-1',
      'first_name': 'Ana',
      'last_name': 'Rojas',
      'photo_url': '',
      'status': 'idle',
    },
  };

  /// Mounts the real [RiderApp] with the router booted at `/home` (a browser
  /// reload), a hermetic location/map seam set, and a staged session. Returns
  /// after the first frame — the bootstrap is still in flight, so the router
  /// is holding `/home` at the splash spinner.
  Future<void> pumpReload(
    WidgetTester tester, {
    required bool hasSession,
  }) async {
    final storage = MockAuthStorage();
    final ws = MockWebSocketService();
    final apiClient = ApiClient(baseUrl: 'http://localhost:8080');
    final dioAdapter = DioAdapter(dio: apiClient.dio);

    when(() => storage.getAccessToken())
        .thenAnswer((_) async => hasSession ? 'access' : null);
    when(() => storage.getRefreshToken())
        .thenAnswer((_) async => hasSession ? 'refresh' : null);
    when(() => storage.getRememberedEmail()).thenAnswer((_) async => null);
    when(() => storage.clearTokens()).thenAnswer((_) async {});
    when(() => ws.events)
        .thenAnswer((_) => const Stream<Map<String, dynamic>>.empty());
    when(() => ws.connect(token: any(named: 'token'))).thenAnswer((_) async {});
    when(() => ws.disconnect()).thenAnswer((_) async {});

    dioAdapter.onGet(
      ApiEndpoints.riderMe,
      (server) => server.reply(200, riderMeData),
    );
    dioAdapter.onGet(
      ApiEndpoints.currentRide,
      (server) => server.reply(200, {
        'ride': null,
        'stops': <dynamic>[],
      }),
    );
    dioAdapter.onGet(
      ApiEndpoints.nearbyDrivers,
      (server) => server.reply(200, {'drivers': <dynamic>[]}),
    );

    // Hermetic device-location seam: granted, but no fix, so Home never touches
    // the platform channel (which never answers under `flutter_test`).
    final fakeLocation = LocationService(
      isServiceEnabled: () async => true,
      requestPermissionDetailed: () async =>
          (granted: true, deniedPermanently: false),
      getCurrentPosition: () async => null,
      openAppSettings: () async => true,
      openLocationSettings: () async => true,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authStorageProvider.overrideWithValue(storage),
          apiClientProvider.overrideWithValue(apiClient),
          webSocketServiceProvider.overrideWithValue(ws),
          // The seam: boot the router at a shell location, as a browser reload
          // would, instead of the production `/splash`.
          routerInitialLocationProvider.overrideWithValue('/home'),
          locationServiceProvider.overrideWithValue(fakeLocation),
          mapTileLayerProvider.overrideWith((ref, config) => null),
        ],
        child: const RiderApp(),
      ),
    );

    // First frame: the bootstrap has not settled yet, so `resolveRedirect` is
    // still holding the reloaded location at the splash spinner.
    await tester.pump();
  }

  testWidgets(
      'T1: a stored session booted at /home resolves to HomeScreen, never '
      'LoginScreen', (tester) async {
    await pumpReload(tester, hasSession: true);

    // Unresolved bootstrap → splash spinner (not a premature /login bounce).
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(LoginScreen), findsNothing);

    // Once the bootstrap settles, the same session stays on the reloaded
    // shell location — the exact web-reload regression.
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);
  });

  testWidgets(
      'T2: no stored session booted at /home resolves to LoginScreen '
      '(negative control)', (tester) async {
    await pumpReload(tester, hasSession: false);

    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
