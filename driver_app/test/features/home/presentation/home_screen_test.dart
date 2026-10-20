import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/location/location_service.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/features/driver/model/driver_profile.dart';
import 'package:driver_app/features/home/presentation/background_tracking_notice.dart';
import 'package:driver_app/features/home/presentation/home_screen.dart';
import 'package:driver_app/features/home/providers/availability_notifier.dart';
import 'package:driver_app/features/navigation/driver_shell.dart';
import 'package:driver_app/features/rides/presentation/offer_sheet.dart';
import 'package:driver_app/features/trip/presentation/trip_screen.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockDriverWebSocketService extends Mock
    implements DriverWebSocketService {}

/// No geolocator platform channel under flutter_test: the stream stays empty
/// and the permission request is already granted.
class FakeLocationService extends LocationService {
  FakeLocationService({
    required super.apiClient,
    required super.availabilityNotifier,
  }) : super(positionStreamProvider: () => const Stream<Position>.empty());

  @override
  Future<bool> requestPermission() async => true;
}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late RideStateNotifier rideState;
  late ProviderContainer container;

  const profile = DriverProfile(
    userId: 'd1',
    firstName: 'Ada',
    lastName: 'Lovelace',
    status: 'offline',
  );

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    // The launch restore is opt-in per test; by default there is no ride.
    when(() => mockDio.get(ApiEndpoints.driverRidesCurrent)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverRidesCurrent),
        statusCode: 200,
        data: {'ride': null},
      ),
    );
    final mockWs = MockDriverWebSocketService();
    when(() => mockWs.events).thenAnswer((_) => const Stream<WsEvent>.empty());
    rideState = RideStateNotifier(mockWs, apiClient: MockApiClient());

    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        driverProfileProvider.overrideWith((ref) => profile),
        appPermissionProvider.overrideWith(
          (ref) => const AppPermissionState(granted: true),
        ),
        mapTileLayerProvider.overrideWith((ref, config) => null),
        locationServiceProvider.overrideWith(
          (ref) => FakeLocationService(
            apiClient: mockApiClient,
            availabilityNotifier: ref.read(availabilityProvider.notifier),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  void holdRide({String status = 'accepted', String rideId = 'r1'}) {
    rideState.onWsEvent(
      WsEvent(
        type: WsEventType.updated,
        data: {
          'ride_id': rideId,
          'status': status,
          'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
          'dropoff': {'lat': 9.95, 'lng': -84.1, 'address': 'Airport'},
        },
      ),
    );
  }

  Future<void> pumpHome(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        // Home runs inside its real shell since bug #10: the screen is
        // body-only and the shell owns the Scaffold/AppBar/drawer.
        GoRoute(
          path: '/home',
          builder: (_, _) =>
              const DriverShell(location: '/home', child: HomeScreen()),
        ),
        GoRoute(path: '/trip', builder: (_, _) => const TripScreen()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('stays home when no ride is held', (tester) async {
    await pumpHome(tester);

    expect(find.text('Offline'), findsOneWidget);
    expect(find.byType(AppBadge), findsOneWidget);
    expect(find.byKey(const Key('home-active-trip')), findsNothing);
    expect(find.text('Trip'), findsNothing);
  });

  testWidgets('pushes the trip screen once a ride is held', (tester) async {
    await pumpHome(tester);
    expect(find.text('Offline'), findsOneWidget);

    holdRide();
    await tester.pumpAndSettle();

    expect(find.byType(TripScreen), findsOneWidget);
    expect(find.text('Drive to the pickup'), findsOneWidget);
  });

  testWidgets(
    'an accept_failed on Home clears the phantom and a later accepted ride '
    'still pushes /trip',
      (tester) async {
      await pumpHome(tester);

      // Pre-fix shape: an optimistic accepted placeholder with no coordinates.
      rideState.onWsEvent(
        WsEvent(
          type: WsEventType.updated,
          data: {'ride_id': 'r1', 'status': 'accepted'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TripScreen), findsOneWidget);

      // Back to Home (a non-terminal trip may be left).
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);

      rideState.onWsEvent(
        const WsEvent(
          type: WsEventType.acceptFailed,
          data: {
            'ride_id': 'r1',
            'code': 'OFFER_EXPIRED',
            'message': 'Offer expired',
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(rideState.state.currentRide, isNull);
      expect(find.byType(TripScreen), findsNothing);

      // The latch reset by the null ride must let a real accepted ride push.
      holdRide();
      await tester.pumpAndSettle();
      expect(find.byType(TripScreen), findsOneWidget);
    },
  );

  testWidgets('the Home-mount fallback restores a ride the bootstrap did not', (
    tester,
  ) async {
    // This mount happens without `SessionBootstrap.run()` (as in a standalone
    // widget test), so `restoreAttempted` is false and Home's own
    // `_restoreActiveTrip` fetches. In production the bootstrap owns the launch
    // restore and the login restore — see
    // `test/core/router/app_router_test.dart` for both production entry paths.
    when(() => mockDio.get(ApiEndpoints.driverRidesCurrent)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverRidesCurrent),
        statusCode: 200,
        data: {
          'ride': {
            'id': 'r9',
            'rider_id': 'u1',
            'status': 'in_progress',
            'pickup_lat': 9.93,
            'pickup_lng': -84.08,
            'dropoff_lat': 9.95,
            'dropoff_lng': -84.1,
          },
        },
      ),
    );

    await pumpHome(tester);
    await tester.pumpAndSettle();

    verify(() => mockDio.get(ApiEndpoints.driverRidesCurrent)).called(1);
    expect(rideState.state.currentRide!.id, 'r9');
    expect(find.byType(TripScreen), findsOneWidget);
    expect(find.text('Driving to the dropoff'), findsOneWidget);
  });

  testWidgets('a failed restore leaves the driver on home', (tester) async {
    when(
      () => mockDio.get(ApiEndpoints.driverRidesCurrent),
    ).thenThrow(DioException(requestOptions: RequestOptions(path: '/stub')));

    await pumpHome(tester);

    expect(rideState.state.currentRide, isNull);
    expect(find.byType(TripScreen), findsNothing);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('the banner re-enters the trip without re-pushing in a loop', (
    tester,
  ) async {
    holdRide();
    await pumpHome(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TripScreen), findsOneWidget);

    // Backing out mid-trip (the PopScope lets non-terminal trips pop) must
    // leave a way back in, and must not bounce the driver into /trip again.
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('home-active-trip')), findsOneWidget);
    expect(find.text('Active trip (accepted)'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byType(TripScreen), findsNothing);

    await tester.tap(find.byKey(const Key('home-active-trip')));
    await tester.pumpAndSettle();

    expect(find.byType(TripScreen), findsOneWidget);
  });

  testWidgets(
    'a lost accept 200 with a WS accepted leaves the trip route, not the '
    'offer sheet, on top',
    (tester) async {
      // Regression (final adversarial review): with the POST still outstanding,
      // the WS `ride.updated accepted` cleared the offer while Home pushed
      // `/trip`. The sheet deferred the clear because `_accepting`, then the
      // 10 s failure path popped the *top* route (`/trip`) and left the sheet
      // trapped with Accept blocked and Pass on a null offer id.
      final accept = Completer<Response<dynamic>>();
      when(
        () => mockDio.post(ApiEndpoints.driverRideAccept('r1')),
      ).thenAnswer((_) => accept.future);
      when(() => mockDio.get(ApiEndpoints.driverRideById('r1'))).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(
            path: ApiEndpoints.driverRideById('r1'),
          ),
          statusCode: 200,
          data: {
            'ride': {
              'id': 'r1',
              'rider_id': 'u1',
              'status': 'pending',
              'pickup_lat': 9.93,
              'pickup_lng': -84.08,
              'pickup_address': 'Central Park',
              'dropoff_lat': 9.95,
              'dropoff_lng': -84.1,
              'dropoff_address': 'Airport',
            },
          },
        ),
      );

      await pumpHome(tester);
      rideState.onWsEvent(
        WsEvent(type: WsEventType.offer, data: {'ride_id': 'r1'}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OfferSheet), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pump();

      // The server committed and broadcast the accepted ride, but the POST's
      // 200 is still outstanding (ultimately lost). The sheet must close now,
      // before or under Home's post-frame `/trip` push.
      holdRide();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.byType(TripScreen), findsOneWidget);
      expect(find.byType(OfferSheet), findsNothing);
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Pass'), findsNothing);

      // The Dio timeout/failure lands later: it must not pop `/trip`, repaint
      // `Offer expired`, or show a failure over the committed accept.
      accept.completeError(Exception('receive timeout'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(TripScreen), findsOneWidget);
      expect(find.byType(OfferSheet), findsNothing);
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Could not accept. Please try again.'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(rideState.state.currentRide!.id, 'r1');
      expect(rideState.state.currentRide!.status, 'accepted');
    },
  );

  testWidgets(
    'an offer opens the sheet even when the profile cache says offline',
    (tester) async {
      // Regression: the sheet used to be gated on `driverProfileProvider`'s
      // `isOnline`, and the status toggle never wrote the new status back into
      // that cache — so a driver who had just gone online (correctly showing
      // "You're online" and a checked switch) silently dropped every offer the
      // websocket delivered, and it then expired after 30 s. The gate must read
      // the offer, not a cache that can be stale or not yet loaded.
      //
      // `profile` above is `status: 'offline'`, i.e. exactly that stale state.
      expect(container.read(driverProfileProvider)?.isOnline, isFalse);

      await pumpHome(tester);
      expect(find.byType(OfferSheet), findsNothing);

      rideState.onWsEvent(
        WsEvent(type: WsEventType.offer, data: {'ride_id': 'r7'}),
      );
      await tester.pumpAndSettle();

      expect(find.byType(OfferSheet), findsOneWidget);
      expect(find.text('New Ride Offer'), findsOneWidget);

      // Withdraw the offer: `_onOffer` arms a 30 s expiry timer and flutter_test
      // fails the test if one is still pending when the tree is torn down.
      rideState.declineOffer();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a later offer still opens after the first is withdrawn', (
    tester,
  ) async {
    await pumpHome(tester);

    rideState.onWsEvent(
      WsEvent(type: WsEventType.offer, data: {'ride_id': 'r7'}),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OfferSheet), findsOneWidget);

    // Dismiss the sheet, then let the offer go (declined, or the 30 s timer).
    Navigator.of(tester.element(find.byType(OfferSheet))).pop();
    await tester.pumpAndSettle();
    rideState.declineOffer();
    await tester.pumpAndSettle();
    expect(find.byType(OfferSheet), findsNothing);

    // The old latch was a bare bool cleared only in the sheet's `.then()`; a
    // driver who never saw the first offer would be shielded from the second
    // one forever. Keying it to the ride id releases it when the offer goes.
    rideState.onWsEvent(
      WsEvent(type: WsEventType.offer, data: {'ride_id': 'r8'}),
    );
    await tester.pumpAndSettle();

    expect(find.byType(OfferSheet), findsOneWidget);

    // See above: cancel the outstanding 30 s expiry timer before teardown.
    rideState.declineOffer();
    await tester.pumpAndSettle();
  });

  testWidgets('a live offer is not dismissed by the barrier or back', (
    tester,
  ) async {
    await pumpHome(tester);

    rideState.onWsEvent(
      WsEvent(type: WsEventType.offer, data: {'ride_id': 'r7'}),
    );
    await tester.pumpAndSettle();
    expect(find.byType(OfferSheet), findsOneWidget);

    // Barrier tap (top-left, outside the sheet) must not dismiss it.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.byType(OfferSheet), findsOneWidget);

    // The system back gesture must not dismiss it either.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(OfferSheet), findsOneWidget);

    // The explicit Pass is the only exit.
    await tester.tap(find.text('Pass'));
    await tester.pumpAndSettle();
    expect(find.byType(OfferSheet), findsNothing);
  });

  testWidgets('the denial banner renders when permission is permanently denied', (
    tester,
  ) async {
    // Override the provider to simulate a permanent denial.
    final deniedContainer = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        driverProfileProvider.overrideWith((ref) => profile),
        appPermissionProvider.overrideWith(
          (ref) =>
              const AppPermissionState(granted: false, deniedPermanently: true),
        ),
        mapTileLayerProvider.overrideWith((ref, config) => null),
        locationServiceProvider.overrideWith(
          (ref) => FakeLocationService(
            apiClient: mockApiClient,
            availabilityNotifier: ref.read(availabilityProvider.notifier),
          ),
        ),
      ],
    );
    addTearDown(deniedContainer.dispose);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) =>
              const DriverShell(location: '/home', child: HomeScreen()),
        ),
        GoRoute(path: '/trip', builder: (_, _) => const TripScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: deniedContainer,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        'Location access denied. Turn it on in settings to receive ride offers.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('going online shows the background-tracking notice once', (
    tester,
  ) async {
    var opened = 0;
    when(
      () => mockDio.put(ApiEndpoints.driverMeStatus, data: any(named: 'data')),
    ).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMeStatus),
        statusCode: 200,
        data: {
          'driver': {
            'user_id': 'd1',
            'first_name': 'Ada',
            'last_name': 'Lovelace',
            'status': 'online',
          },
        },
      ),
    );

    final noticeContainer = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        driverProfileProvider.overrideWith((ref) => profile),
        appPermissionProvider.overrideWith(
          (ref) => const AppPermissionState(granted: true),
        ),
        mapTileLayerProvider.overrideWith((ref, config) => null),
        openAppSettingsProvider.overrideWithValue(() async {
          opened++;
          return true;
        }),
        locationServiceProvider.overrideWith(
          (ref) => FakeLocationService(
            apiClient: mockApiClient,
            availabilityNotifier: ref.read(availabilityProvider.notifier),
          ),
        ),
      ],
    );
    addTearDown(noticeContainer.dispose);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) =>
              const DriverShell(location: '/home', child: HomeScreen()),
        ),
        GoRoute(path: '/trip', builder: (_, _) => const TripScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: noticeContainer,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('background-tracking-notice')),
      findsNothing,
      reason: 'the notice is only shown once the driver goes online',
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('background-tracking-notice')), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('background-tracking-open-settings')),
    );
    await tester.pumpAndSettle();
    expect(opened, 1, reason: 'the settings deep-link must fire');
    expect(
      noticeContainer.read(backgroundTrackingNoticeShownProvider),
      isTrue,
      reason: 'the notice must not be shown again this session',
    );
  });

  testWidgets('the permanent-denial banner offers the settings deep-link', (
    tester,
  ) async {
    var opened = 0;
    final deniedContainer = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        driverProfileProvider.overrideWith((ref) => profile),
        appPermissionProvider.overrideWith(
          (ref) =>
              const AppPermissionState(granted: false, deniedPermanently: true),
        ),
        mapTileLayerProvider.overrideWith((ref, config) => null),
        openAppSettingsProvider.overrideWithValue(() async {
          opened++;
          return true;
        }),
        locationServiceProvider.overrideWith(
          (ref) => FakeLocationService(
            apiClient: mockApiClient,
            availabilityNotifier: ref.read(availabilityProvider.notifier),
          ),
        ),
      ],
    );
    addTearDown(deniedContainer.dispose);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) =>
              const DriverShell(location: '/home', child: HomeScreen()),
        ),
        GoRoute(path: '/trip', builder: (_, _) => const TripScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: deniedContainer,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('denied-open-settings')));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
