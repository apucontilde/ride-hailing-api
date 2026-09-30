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
import 'package:driver_app/features/home/presentation/home_screen.dart';
import 'package:driver_app/features/home/providers/availability_notifier.dart';
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
    when(() => mockWs.events)
        .thenAnswer((_) => const Stream<WsEvent>.empty());
    rideState = RideStateNotifier(mockWs, apiClient: MockApiClient());

    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        driverProfileProvider.overrideWith((ref) => profile),
        appPermissionProvider
            .overrideWith((ref) => const AppPermissionState(granted: true)),
        tripMapTileProvider.overrideWith((ref) => null),
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
    rideState.onWsEvent(WsEvent(
      type: WsEventType.updated,
      data: {
        'ride_id': rideId,
        'status': status,
        'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
        'dropoff': {'lat': 9.95, 'lng': -84.1, 'address': 'Airport'},
      },
    ));
  }

  Future<void> pumpHome(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
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

  testWidgets('a ride restored on launch opens the trip', (tester) async {
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
    when(() => mockDio.get(ApiEndpoints.driverRidesCurrent)).thenThrow(
      DioException(requestOptions: RequestOptions(path: '/stub')),
    );

    await pumpHome(tester);

    expect(rideState.state.currentRide, isNull);
    expect(find.byType(TripScreen), findsNothing);
    expect(find.text('Offline'), findsOneWidget);
  });

  testWidgets('the banner re-enters the trip without re-pushing in a loop',
      (tester) async {
    holdRide();
    await pumpHome(tester);
    await tester.pumpAndSettle();
    expect(find.byType(TripScreen), findsOneWidget);

    // Backing out mid-trip (the PopScope lets non-terminal trips pop) must
    // leave a way back in, and must not bounce the driver into /trip again.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
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

  testWidgets('an offer opens the sheet even when the profile cache says offline',
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
  });

  testWidgets('a later offer still opens after the first is withdrawn',
      (tester) async {
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

  testWidgets('the denial banner renders when permission is permanently denied',
      (tester) async {
    // Override the provider to simulate a permanent denial.
    final deniedContainer = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => rideState),
        driverProfileProvider.overrideWith((ref) => profile),
        appPermissionProvider.overrideWith(
          (ref) => const AppPermissionState(
            granted: false,
            deniedPermanently: true,
          ),
        ),
        tripMapTileProvider.overrideWith((ref) => null),
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
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
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

    expect(find.text('Location access denied. Turn it on in settings to receive ride offers.'), findsOneWidget);
  });
}
