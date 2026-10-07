import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/core/network/websocket_service.dart';
import 'package:driver_app/core/network/ws_event.dart';
import 'package:driver_app/core/ride/ride_state_notifier.dart';
import 'package:driver_app/features/rides/data/rides_repository.dart';
import 'package:driver_app/features/rides/presentation/offer_sheet.dart';

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

  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          rideStateProvider.overrideWith((ref) => notifier),
          ridesRepositoryProvider.overrideWith((ref) => mockRepo),
          driverWebSocketServiceProvider.overrideWithValue(mockWs),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (context) => const OfferSheet(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
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

  testWidgets('renders the real cents, never rounded to whole dollars',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Central Park'), findsOneWidget);
    expect(find.text('Airport'), findsOneWidget);
    expect(find.text('12.40'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('prefixes the API currency when the ride carries one',
      (tester) async {
    await seedOffer(tester, 'r1');
    stubRide(fareCurrency: 'USD');
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('USD12.40'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keeps the placeholder for a ride with no fare', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide(totalFare: null);
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('-'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('countdown reaches 0 and disables both buttons', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);

    await tester.pump(const Duration(seconds: 31));

    expect(find.text('Offer expired'), findsOneWidget);
    final accept = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Accept'),
        matching: find.byType(FilledButton),
      ),
    );
    final decline = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Decline'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(accept.onPressed, isNull);
    expect(decline.onPressed, isNull);

    await tester.pumpWidget(const SizedBox());
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

    await tester.pumpWidget(const SizedBox());
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

    await tester.pumpWidget(const SizedBox());
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

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('decline sends WS decline and closes the sheet', (tester) async {
    await seedOffer(tester, 'r1');
    stubRide();
    await pumpSheet(tester);
    await tester.pump();

    await tester.tap(find.text('Decline'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    verify(() => mockWs.declineOffer('r1')).called(1);
    expect(notifier.state.offeredRideId, isNull);
    expect(find.byType(OfferSheet), findsNothing);

    await tester.pumpWidget(const SizedBox());
  });
}