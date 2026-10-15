import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/features/rides/data/rides_repository.dart';
import 'package:driver_app/features/rides/presentation/offer_sheet.dart';

import '../../../support/sheet_harness.dart';

class MockDriverWebSocketService extends Mock
    implements DriverWebSocketService {}

class MockRidesRepository extends Mock implements RidesRepository {}

class MockApiClient extends Mock implements ApiClient {}

void main() {
  late MockDriverWebSocketService mockWs;
  late MockRidesRepository mockRepo;
  late StreamController<WsEvent> events;
  late RideStateNotifier notifier;

  setUp(() {
    mockWs = MockDriverWebSocketService();
    mockRepo = MockRidesRepository();
    events = StreamController<WsEvent>.broadcast();
    when(() => mockWs.events).thenAnswer((_) => events.stream);
    addTearDown(() => events.close());
  });

  Future<void> seedOffer(WidgetTester tester, String rideId) async {
    notifier = RideStateNotifier(
      mockWs,
      apiClient: MockApiClient(),
      offerTimeout: const Duration(minutes: 5),
    );
    events.add(WsEvent(type: WsEventType.offer, data: {'ride_id': rideId}));
    await tester.pump();
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    bool isDismissible = false,
    bool enableDrag = false,
  }) {
    return pumpModalSheet(
      tester,
      overrides: [
        rideStateProvider.overrideWith((ref) => notifier),
        ridesRepositoryProvider.overrideWith((ref) => mockRepo),
        driverWebSocketServiceProvider.overrideWithValue(mockWs),
      ],
      builder: (context) => const OfferSheet(),
      isDismissible: isDismissible,
      enableDrag: enableDrag,
    );
  }

  void stubRide({double? totalFare = 12.4, String? fareCurrency}) {
    when(() => mockRepo.fetchRide('r1')).thenAnswer(
      (_) async => Ride(
        id: 'r1',
        riderId: 'u1',
        status: 'pending',
        pickupLat: 9.93,
        pickupLng: -84.08,
        pickupAddress: 'Central Park',
        dropoffLat: 9.95,
        dropoffLng: -84.10,
        dropoffAddress: 'Airport',
        totalFare: totalFare,
        fareCurrency: fareCurrency,
      ),
    );
  }

  void stubEstimate({
    double distanceM = 4200,
    int durationS = 420,
    bool isEstimate = false,
  }) {
    when(() => mockRepo.routeEstimate(
          fromLat: any(named: 'fromLat'),
          fromLng: any(named: 'fromLng'),
          toLat: any(named: 'toLat'),
          toLng: any(named: 'toLng'),
        )).thenAnswer(
      (_) async => RouteEstimate(
        distanceM: distanceM,
        durationS: durationS,
        isEstimate: isEstimate,
      ),
    );
  }

  testWidgets('renders the trip distance and estimated time', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    stubEstimate();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Distance'), findsOneWidget);
    expect(find.text('4.2 km'), findsOneWidget);
    expect(find.text('Est. time'), findsOneWidget);
    expect(find.text('about 7 min'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('labels an out-of-coverage estimate', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    stubEstimate(distanceM: 2900, durationS: 260, isEstimate: true);
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Estimated 2.9 km'), findsOneWidget);
    expect(find.text('Estimated about 5 min'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('a failed estimate shows the placeholder, never a number',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(() => mockRepo.routeEstimate(
          fromLat: any(named: 'fromLat'),
          fromLng: any(named: 'fromLng'),
          toLat: any(named: 'toLat'),
          toLng: any(named: 'toLng'),
        )).thenThrow(Exception('no route'));
    await pumpSheet(tester);
    await tester.pump();

    // Both estimate rows fall back to the placeholder; no fabricated values.
    expect(find.text('—'), findsNWidgets(2));

    await drainModalTimers(tester);
  });

  testWidgets('renders the real cents, never rounded to whole dollars',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Central Park'), findsOneWidget);
    expect(find.text('Airport'), findsOneWidget);
    expect(find.text('12.40'), findsOneWidget);
    // The sheet surface and its two actions are the shared widgets.
    expect(find.byType(AppBottomSheet), findsOneWidget);
    expect(find.byType(AppButton), findsNWidgets(2));

    await drainModalTimers(tester);
  });

  testWidgets('prefixes the API currency when the ride carries one',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide(fareCurrency: 'USD');
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('USD12.40'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('keeps the placeholder for a ride with no fare', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide(totalFare: null);
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('-'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('expiry replaces the actions with a single Dismiss',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Pass'), findsOneWidget);

    await tester.pump(const Duration(seconds: 31));

    expect(find.text('Offer expired'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Pass'), findsNothing);

    await tester.tap(find.byKey(const Key('offer-dismiss-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(OfferSheet), findsNothing);

    await drainModalTimers(tester);
  });

  testWidgets('the held offer clearing pins the sheet to its expired Dismiss',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Accept'), findsOneWidget);

    // The server's 30 s window (or an acceptance elsewhere) clears the offer.
    notifier.declineOffer();
    await tester.pump();

    expect(find.text('Offer expired'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);
    expect(find.byType(OfferSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key('offer-dismiss-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(OfferSheet), findsNothing);

    await drainModalTimers(tester);
  });

  testWidgets(
      'a replaced live offer closes the previous sheet instead of stacking',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();
    expect(find.byType(OfferSheet), findsOneWidget);

    // The first offer ends (the server's window, or an acceptance elsewhere),
    // pinning this sheet to its expired Dismiss state. A new live offer then
    // arrives. The stale sheet must actually pop — under `PopScope(canPop:
    // false)` `maybePop` was a no-op, so it stayed stacked under the second
    // sheet the parent opened.
    notifier.declineOffer();
    await tester.pump();
    expect(find.text('Offer expired'), findsOneWidget);

    events.add(WsEvent(type: WsEventType.offer, data: {'ride_id': 'r2'}));
    await tester.pump();
    // Let the modal exit animation finish.
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(OfferSheet), findsNothing);

    // Cancel the second offer's outstanding expiry timer before teardown.
    notifier.declineOffer();
    await drainModalTimers(tester);
  });

  testWidgets('a live offer survives the system back gesture', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(OfferSheet), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('accept over a live websocket sends nested accept and pops',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(() => mockWs.isConnected).thenReturn(true);
    await pumpSheet(tester);
    await tester.pump();

    await tester.tap(find.text('Accept'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => mockWs.acceptOffer('r1')).called(1);
    verifyNever(() => mockRepo.acceptRideHttp(any()));
    expect(notifier.state.currentRide, isNotNull);
    expect(find.text('Trip accepted'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('accept with a dead websocket falls back to HTTP',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(() => mockWs.isConnected).thenReturn(false);
    when(() => mockRepo.acceptRideHttp('r1')).thenAnswer((_) async {});
    await pumpSheet(tester);
    await tester.pump();

    await tester.tap(find.text('Accept'));
    await tester.pump();

    verifyNever(() => mockWs.acceptOffer(any()));
    verify(() => mockRepo.acceptRideHttp('r1')).called(1);
    expect(notifier.state.currentRide, isNotNull);
    expect(find.text('Trip accepted'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('409 from the HTTP fallback shows trip no longer available',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(() => mockWs.isConnected).thenReturn(false);
    when(() => mockRepo.acceptRideHttp('r1'))
        .thenThrow(OfferExpiredException());
    await pumpSheet(tester);
    await tester.pump();

    await tester.tap(find.text('Accept'));
    await tester.pump();

    expect(find.text('Trip no longer available'), findsOneWidget);
    expect(notifier.state.currentRide, isNull);

    await drainModalTimers(tester);
  });

  testWidgets('Pass sends WS decline and closes the sheet', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    await tester.tap(find.text('Pass'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => mockWs.declineOffer('r1')).called(1);
    expect(notifier.state.offeredRideId, isNull);
    expect(find.byType(OfferSheet), findsNothing);

    await drainModalTimers(tester);
  });
}