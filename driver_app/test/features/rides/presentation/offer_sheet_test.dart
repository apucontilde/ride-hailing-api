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

  Future<void> seedOffer(
    WidgetTester tester,
    String rideId, {
    Duration offerTimeout = const Duration(minutes: 5),
  }) async {
    notifier = RideStateNotifier(
      mockWs,
      apiClient: MockApiClient(),
      offerTimeout: offerTimeout,
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
    when(
      () => mockRepo.routeEstimate(
          fromLat: any(named: 'fromLat'),
          fromLng: any(named: 'fromLng'),
          toLat: any(named: 'toLat'),
          toLng: any(named: 'toLng'),
      ),
    ).thenAnswer(
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

  testWidgets('a failed estimate shows the placeholder, never a number', (
    tester,
  ) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(
      () => mockRepo.routeEstimate(
          fromLat: any(named: 'fromLat'),
          fromLng: any(named: 'fromLng'),
          toLat: any(named: 'toLat'),
          toLng: any(named: 'toLng'),
      ),
    ).thenThrow(Exception('no route'));
    await pumpSheet(tester);
    await tester.pump();

    // Both estimate rows fall back to the placeholder; no fabricated values.
    expect(find.text('—'), findsNWidgets(2));

    await drainModalTimers(tester);
  });

  testWidgets('renders the real cents, never rounded to whole dollars', (
    tester,
  ) async {
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

  testWidgets('prefixes the API currency when the ride carries one', (
    tester,
  ) async {
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

  testWidgets('expiry replaces the actions with a single Dismiss', (
    tester,
  ) async {
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

  testWidgets('the held offer clearing pins the sheet to its expired Dismiss', (
    tester,
  ) async {
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
    },
  );

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

  // ---------------------------------------------------------------- accept
  //
  // Accept is HTTP-primary and server-confirmed. A `200` is followed by a real
  // `GET /driver/rides/:id`; only that ride is adopted. The offer sheet must
  // never paint `Offer expired` for a committed accept (manual review
  // 2026-10-19), including during the pop animation or after a late
  // `ride.offer_closed {reason:"expired"}` frame.

  Ride pendingRide() => const Ride(
    id: 'r1',
    riderId: 'u1',
    status: 'pending',
    pickupLat: 9.93,
    pickupLng: -84.08,
    pickupAddress: 'Central Park',
    dropoffLat: 9.95,
    dropoffLng: -84.10,
    dropoffAddress: 'Airport',
    totalFare: 12.4,
  );

  Ride acceptedRide({String status = 'accepted'}) => Ride(
    id: 'r1',
    riderId: 'u1',
    status: status,
    pickupLat: 9.93,
    pickupLng: -84.08,
    pickupAddress: 'Central Park',
    dropoffLat: 9.95,
    dropoffLng: -84.10,
    dropoffAddress: 'Airport',
    totalFare: 12.4,
  );

  /// The sheet loads the pending ride first; the post-accept read returns
  /// [second] (default: a real accepted ride).
  void stubPendingThenRead(Ride Function() second) {
    var calls = 0;
    when(() => mockRepo.fetchRide('r1')).thenAnswer((_) async {
      calls++;
      return calls == 1 ? pendingRide() : second();
    });
  }

  void stubPostAcceptRead(Future<Ride> Function() second) {
    var calls = 0;
    when(() => mockRepo.fetchRide('r1')).thenAnswer((_) async {
      calls++;
      if (calls == 1) return pendingRide();
      return second();
    });
  }

  void stubAccept200() {
    when(() => mockRepo.acceptRideHttp('r1')).thenAnswer((_) async {});
  }

  Future<void> tapAccept(WidgetTester tester) async {
    await tester.tap(find.text('Accept'));
    await tester.pump();
  }

  testWidgets(
    "a live-socket accept never paints 'Offer expired' during the pop "
    '(manual review 2026-10-19)',
      (tester) async {
    await seedOffer(tester, 'r1');
    when(() => mockWs.isConnected).thenReturn(true);
      stubAccept200();
      stubPendingThenRead(acceptedRide);
    await pumpSheet(tester);
    await tester.pump();

      await tapAccept(tester);
      await tester.pump(const Duration(milliseconds: 150));

      verify(() => mockRepo.acceptRideHttp('r1')).called(1);
      verifyNever(() => mockWs.declineOffer(any()));
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.pickupLat, 9.93);
      expect(notifier.state.offeredRideId, isNull);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    "the dead-socket HTTP 200 path never paints 'Offer expired' during the "
    'pop',
    (tester) async {
      await seedOffer(tester, 'r1');
      when(() => mockWs.isConnected).thenReturn(false);
      stubAccept200();
      stubPendingThenRead(acceptedRide);
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump(const Duration(milliseconds: 150));

      verify(() => mockRepo.acceptRideHttp('r1')).called(1);
      verifyNever(() => mockWs.declineOffer(any()));
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.pickupLat, 9.93);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a late offer_closed expired during the post-200 ride read does not '
    'expire the sheet',
    (tester) async {
      await seedOffer(tester, 'r1');
      stubAccept200();
      final read = Completer<Ride>();
      stubPostAcceptRead(() => read.future);
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      events.add(
        const WsEvent(
          type: WsEventType.offerClosed,
          data: {'ride_id': 'r1', 'reason': 'expired'},
        ),
      );
      await tester.pump();

      expect(find.text('Offer expired'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(find.byType(OfferSheet), findsOneWidget);

      read.complete(acceptedRide());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Trip accepted'), findsOneWidget);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a late offer_closed expired while the post-200 Retry is pending does '
    'not expire and Retry still pops',
    (tester) async {
      await seedOffer(tester, 'r1');
      stubAccept200();
      var calls = 0;
      when(() => mockRepo.fetchRide('r1')).thenAnswer((_) async {
        calls++;
        if (calls == 1) return pendingRide();
        throw Exception('read failed');
      });
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      events.add(
        const WsEvent(
          type: WsEventType.offerClosed,
          data: {'ride_id': 'r1', 'reason': 'expired'},
        ),
      );
      await tester.pump();

      expect(find.byKey(const Key('offer-retry-button')), findsOneWidget);
      expect(find.text('Offer expired'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);

      when(
        () => mockRepo.fetchRide('r1'),
      ).thenAnswer((_) async => acceptedRide());
      await tester.tap(find.byKey(const Key('offer-retry-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Trip accepted'), findsOneWidget);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);
      expect(notifier.state.currentRide!.pickupLat, 9.93);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a slow accept past the notifier offer deadline never paints '
    "'Offer expired'",
    (tester) async {
      // A short notifier deadline makes the race deterministic: the accept POST
      // is still in flight when the notifier's independent timer would fire.
      await seedOffer(tester, 'r1', offerTimeout: const Duration(seconds: 2));
      final accept = Completer<void>();
      when(
        () => mockRepo.acceptRideHttp('r1'),
      ).thenAnswer((_) => accept.future);
      stubPendingThenRead(acceptedRide);
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump(const Duration(seconds: 2, milliseconds: 100));

      // The local deadline must not clear the offer or expire the sheet while
      // the accept's `200` is outstanding; only the server may close it.
      expect(find.text('Offer expired'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(notifier.state.offeredRideId, 'r1');

      accept.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.status, 'accepted');
      expect(notifier.state.currentRide!.pickupLat, 9.93);
      expect(notifier.state.offeredRideId, isNull);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a pre-200 close does not shadow the post-200 Retry',
    (tester) async {
      await seedOffer(tester, 'r1');
      final accept = Completer<void>();
      when(
        () => mockRepo.acceptRideHttp('r1'),
      ).thenAnswer((_) => accept.future);
      final read = Completer<Ride>();
      stubPostAcceptRead(() => read.future);
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      // The rider cancels between the tap and the `200`.
      events.add(
        const WsEvent(
          type: WsEventType.offerClosed,
          data: {'ride_id': 'r1', 'reason': 'cancelled'},
        ),
      );
      await tester.pump();

      // Ignored while the accept is in flight: it must not pin the sheet to
      // the expired Dismiss (which would shadow the committed accept's Retry).
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(find.text('The rider cancelled this trip.'), findsNothing);

      accept.complete();
      await tester.pump();

      // The accept committed (200) but its ride read fails.
      read.completeError(Exception('read failed'));
      await tester.pump();
      await tester.pump();

      expect(find.byKey(const Key('offer-retry-button')), findsOneWidget);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(find.text('Offer expired'), findsNothing);

      when(
        () => mockRepo.fetchRide('r1'),
      ).thenAnswer((_) async => acceptedRide());
      await tester.tap(find.byKey(const Key('offer-retry-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.status, 'accepted');
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a lost 200 after the server committed closes as accepted over the '
    'WS-confirmed ride, never as expired',
    (tester) async {
      await seedOffer(tester, 'r1');
      final accept = Completer<void>();
      when(
        () => mockRepo.acceptRideHttp('r1'),
      ).thenAnswer((_) => accept.future);
      stubRide();
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      // The server committed, broadcast `accepted` to this driver and cleared
      // the offer — but the POST's `200` is lost. The clear was deferred while
      // `_accepting`; the held ride is the server's own accepted ride.
      events.add(
        WsEvent(
          type: WsEventType.updated,
          data: {
            'ride_id': 'r1',
            'status': 'accepted',
            'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
            'dropoff': {'lat': 9.95, 'lng': -84.10, 'address': 'Airport'},
          },
        ),
      );
      await tester.pump();

      expect(notifier.state.currentRide!.status, 'accepted');
      expect(notifier.state.offeredRideId, isNull);

      accept.completeError(Exception('receive timeout'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // One truthful outcome: the committed accept. No expiry, no failure
      // copy, no duplicate POST.
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Could not accept. Please try again.'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(find.byType(OfferSheet), findsNothing);
      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.id, 'r1');
      expect(notifier.state.currentRide!.status, 'accepted');
      expect(notifier.state.currentRide!.pickupLat, 9.93);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a WS accepted arriving after a retryable POST failure still closes as '
    'accepted, never as expired',
    (tester) async {
      await seedOffer(tester, 'r1');
      when(
        () => mockRepo.acceptRideHttp('r1'),
      ).thenThrow(Exception('receive timeout'));
      stubRide();
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      // The POST failed before any clear arrived: the sheet is still usable.
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Offer expired'), findsNothing);

      // The server's late `ride.updated accepted` proves the assignment did
      // commit after all. This is the listener's direct (not-deferred) path.
      events.add(
        WsEvent(
          type: WsEventType.updated,
          data: {
            'ride_id': 'r1',
            'status': 'accepted',
            'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
            'dropoff': {'lat': 9.95, 'lng': -84.10, 'address': 'Airport'},
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Could not accept. Please try again.'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(find.byType(OfferSheet), findsNothing);
      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.status, 'accepted');
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a WS accepted removes the presented sheet route, never a trip route on '
    'top of it',
    (tester) async {
      await seedOffer(tester, 'r1');
      stubRide();
      await pumpSheet(tester);
      await tester.pump();

      // Home pushes `/trip` above the open sheet on the post-frame after the
      // WS accepted arrives. The sheet's route is no longer current.
      final navigator = Navigator.of(tester.element(find.byType(OfferSheet)));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const Scaffold(body: Text('Trip screen')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Trip screen'), findsOneWidget);

      events.add(
        WsEvent(
          type: WsEventType.updated,
          data: {
            'ride_id': 'r1',
            'status': 'accepted',
            'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
            'dropoff': {'lat': 9.95, 'lng': -84.10, 'address': 'Airport'},
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The trip route survives; the sheet's own route was removed instead of
      // popping the top route.
      expect(find.text('Trip screen'), findsOneWidget);
      expect(find.text('Trip accepted'), findsOneWidget);
      expect(find.text('Offer expired'), findsNothing);

      // Leaving the trip lands on the harness home, not a trapped sheet.
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget);
      expect(find.byType(OfferSheet), findsNothing);

      notifier.beginAccept(); // cancel the outstanding offer deadline timer
      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a late WS accepted still closes as accepted after a 404 already cleared '
    'the offer',
    (tester) async {
      await seedOffer(tester, 'r1');
      stubRide();
      var calls = 0;
      when(() => mockRepo.acceptRideHttp('r1')).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw Exception('receive timeout');
        throw OfferExpiredException('no active offer for this ride');
      });
      await pumpSheet(tester);
      await tester.pump();

      // First tap fails retryably: the sheet stays usable and the offer is
      // still held.
      await tapAccept(tester);
      await tester.pump();
      expect(find.text('Accept'), findsOneWidget);
      expect(notifier.state.offeredRideId, 'r1');

      // Second tap answers 404: the offer is cleared and the sheet pins itself
      // to `Trip no longer available`.
      await tapAccept(tester);
      await tester.pump();
      expect(notifier.state.offeredRideId, isNull);
      expect(find.text('Trip no longer available'), findsOneWidget);

      // The server had committed after all. With the offered id already null,
      // only the held-ride listener can recover the accept.
      events.add(
        WsEvent(
          type: WsEventType.updated,
          data: {
            'ride_id': 'r1',
            'status': 'accepted',
            'pickup': {'lat': 9.93, 'lng': -84.08, 'address': 'Central Park'},
            'dropoff': {'lat': 9.95, 'lng': -84.10, 'address': 'Airport'},
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(OfferSheet), findsNothing);
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Trip no longer available'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);
      expect(find.text('Trip accepted'), findsOneWidget);
      expect(notifier.state.currentRide!.status, 'accepted');
      expect(notifier.state.currentRide!.pickupLat, 9.93);
      verify(() => mockRepo.acceptRideHttp('r1')).called(2);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a pre-200 close deferred by an in-flight accept applies once when the '
    'POST fails without committing',
    (tester) async {
      await seedOffer(tester, 'r1');
      final accept = Completer<void>();
      when(
        () => mockRepo.acceptRideHttp('r1'),
      ).thenAnswer((_) => accept.future);
      stubRide();
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      // The rider cancels between the tap and the (never-committed) POST.
      events.add(
        const WsEvent(
          type: WsEventType.offerClosed,
          data: {'ride_id': 'r1', 'reason': 'cancelled'},
        ),
      );
      await tester.pump();

      // Deferred while the POST is in flight: no expired state yet.
      expect(notifier.state.offeredRideId, isNull);
      expect(find.text('The rider cancelled this trip.'), findsNothing);
      expect(find.byKey(const Key('offer-dismiss-button')), findsNothing);

      accept.completeError(Exception('server exploded'));
      await tester.pump();
      await tester.pump();

      // The deferred clear is applied exactly once: one reason copy, one
      // Dismiss, and the sheet is not popped (no double close).
      expect(find.text('Could not accept. Please try again.'), findsOneWidget);
      expect(find.text('The rider cancelled this trip.'), findsOneWidget);
      expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);
      expect(find.text('Offer expired'), findsNothing);
      expect(find.byType(OfferSheet), findsOneWidget);
      expect(notifier.state.currentRide, isNull);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets('a genuine clear with no accept in flight still pins the explicit '
      'Dismiss expiry', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Accept'), findsOneWidget);

    // No accept was committed or in flight: the withdrawal is a genuine close.
    notifier.declineOffer();
    await tester.pump();

    verifyNever(() => mockRepo.acceptRideHttp(any()));
    expect(find.text('Offer expired'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);
    expect(find.byType(OfferSheet), findsOneWidget);

    await tester.tap(find.byKey(const Key('offer-dismiss-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(OfferSheet), findsNothing);

    await drainModalTimers(tester);
  });

  testWidgets('an accept over a live websocket still uses the HTTP endpoint', (
    tester,
  ) async {
    await seedOffer(tester, 'r1');
    when(() => mockWs.isConnected).thenReturn(true);
    stubAccept200();
    stubPendingThenRead(acceptedRide);
    await pumpSheet(tester);
    await tester.pump();

    await tapAccept(tester);
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => mockRepo.acceptRideHttp('r1')).called(1);
    verifyNever(() => mockWs.declineOffer(any()));
    // Only the fetched ride is ever held; no hand-built placeholder.
    expect(notifier.state.currentRide!.pickupLat, 9.93);

    await drainModalTimers(tester);
  });

  testWidgets('200 closes only after the real ride is adopted', (tester) async {
    await seedOffer(tester, 'r1');
    stubAccept200();
    stubPendingThenRead(acceptedRide);
    await pumpSheet(tester);
    await tester.pump();

    await tapAccept(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(notifier.state.currentRide!.pickupLat, isNotNull);
    expect(notifier.state.currentRide!.status, 'accepted');
    expect(notifier.state.offeredRideId, isNull);
    expect(find.byType(OfferSheet), findsNothing);
    expect(find.text('Trip accepted'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets("404 from the HTTP accept closes as expired with 'Trip no longer "
      'available', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(
      () => mockRepo.acceptRideHttp('r1'),
    ).thenThrow(OfferExpiredException('no active offer for this ride'));
    await pumpSheet(tester);
    await tester.pump();

    await tapAccept(tester);
    await tester.pump();

    expect(find.text('Trip no longer available'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);
    expect(notifier.state.currentRide, isNull);
    expect(notifier.state.offeredRideId, isNull);

    await drainModalTimers(tester);
  });

  testWidgets("409 from the HTTP accept closes as expired with 'Trip no longer "
      'available', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    when(
      () => mockRepo.acceptRideHttp('r1'),
    ).thenThrow(OfferExpiredException());
    await pumpSheet(tester);
    await tester.pump();

    await tapAccept(tester);
    await tester.pump();

    expect(find.text('Trip no longer available'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);
    expect(notifier.state.currentRide, isNull);

    await drainModalTimers(tester);
  });

  testWidgets(
    '500 from the HTTP accept keeps the sheet usable and shows a retryable '
    'message',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
      when(
        () => mockRepo.acceptRideHttp('r1'),
      ).thenThrow(Exception('server exploded'));
    await pumpSheet(tester);
    await tester.pump();

      await tapAccept(tester);
      await tester.pump();

      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Pass'), findsOneWidget);
      expect(find.text('Offer expired'), findsNothing);
      expect(find.text('Could not accept. Please try again.'), findsOneWidget);
      expect(notifier.state.currentRide, isNull);

      await drainModalTimers(tester);
    },
  );

  testWidgets('a 200 whose ride read fails offers a retry and never re-POSTs '
      'accept', (tester) async {
    await seedOffer(tester, 'r1');
    stubAccept200();
    var calls = 0;
    when(() => mockRepo.fetchRide('r1')).thenAnswer((_) async {
      calls++;
      if (calls == 1) return pendingRide();
      throw Exception('read failed');
    });
    await pumpSheet(tester);
    await tester.pump();

    await tapAccept(tester);
    await tester.pump();

    expect(find.byKey(const Key('offer-retry-button')), findsOneWidget);
    expect(find.text('Accept'), findsNothing);
    expect(notifier.state.currentRide, isNull);
    expect(find.byType(OfferSheet), findsOneWidget);

    when(
      () => mockRepo.fetchRide('r1'),
    ).thenAnswer((_) async => acceptedRide());
    await tester.tap(find.byKey(const Key('offer-retry-button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => mockRepo.acceptRideHttp('r1')).called(1);
    expect(notifier.state.currentRide!.pickupLat, 9.93);
    expect(find.text('Trip accepted'), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('a 200 whose ride is already cancelled closes as ended, never as '
      'accepted', (tester) async {
    await seedOffer(tester, 'r1');
    stubAccept200();
    stubPendingThenRead(() => acceptedRide(status: 'cancelled'));
    await pumpSheet(tester);
    await tester.pump();

    await tapAccept(tester);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Trip accepted'), findsNothing);
    expect(find.byType(OfferSheet), findsNothing);
    expect(find.text('This trip has already ended.'), findsOneWidget);
    expect(notifier.state.currentRide!.status, 'cancelled');
    verify(() => mockRepo.acceptRideHttp('r1')).called(1);

    await drainModalTimers(tester);
  });

  testWidgets(
    'a 200 whose ride is completed adopts the terminal receipt and does not '
    'claim a live trip',
    (tester) async {
      await seedOffer(tester, 'r1');
      stubAccept200();
      stubPendingThenRead(() => acceptedRide(status: 'completed'));
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Trip accepted'), findsNothing);
      expect(find.byType(OfferSheet), findsNothing);
      expect(notifier.state.currentRide!.status, 'completed');
      expect(notifier.state.offeredRideId, isNull);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets(
    'a 200 whose ride is no_driver_available clears the held ride and stays '
    'on Home',
      (tester) async {
    await seedOffer(tester, 'r1');
      stubAccept200();
      stubPendingThenRead(() => acceptedRide(status: 'no_driver_available'));
      await pumpSheet(tester);
      await tester.pump();

      await tapAccept(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(notifier.state.currentRide, isNull);
      expect(notifier.state.offeredRideId, isNull);
      expect(find.text('Trip accepted'), findsNothing);
      expect(find.text('No active trip.'), findsOneWidget);
      verify(() => mockRepo.acceptRideHttp('r1')).called(1);

      await drainModalTimers(tester);
    },
  );

  testWidgets('a server offer_closed reason cancelled pins the sheet with the '
      'cancelled message', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    events.add(
      const WsEvent(
        type: WsEventType.offerClosed,
        data: {'ride_id': 'r1', 'reason': 'cancelled'},
      ),
    );
    await tester.pump();

    expect(notifier.state.offeredRideId, isNull);
    expect(find.text('The rider cancelled this trip.'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);

    await drainModalTimers(tester);
  });

  testWidgets('a server accept_failed clears the phantom and never claims '
      'the trip', (tester) async {
    // Seed the legacy optimistic placeholder shape (accepted, no coordinates)
    // plus a fresh offer for the same ride.
    notifier = RideStateNotifier(
      mockWs,
      apiClient: MockApiClient(),
      offerTimeout: const Duration(minutes: 5),
    );
    events.add(
      const WsEvent(
        type: WsEventType.updated,
        data: {'ride_id': 'r1', 'status': 'accepted'},
      ),
    );
    await tester.pump();
    events.add(WsEvent(type: WsEventType.offer, data: {'ride_id': 'r1'}));
    await tester.pump();
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    events.add(
      const WsEvent(
        type: WsEventType.acceptFailed,
        data: {
          'ride_id': 'r1',
          'code': 'NOT_OFFERED',
          'message': 'no active offer for this ride',
        },
      ),
    );
    await tester.pump();

    expect(notifier.state.currentRide, isNull);
    expect(find.text('no active offer for this ride'), findsOneWidget);
    expect(find.byKey(const Key('offer-dismiss-button')), findsOneWidget);

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