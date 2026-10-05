import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/core/location/location_service.dart';
import 'package:driver_app/features/safety/data/safety_repository.dart';
import 'package:driver_app/features/safety/presentation/safety_screen.dart';

class MockSafetyRepository extends Mock implements SafetyRepository {}

/// US-12: SOS and feedback are ack-only, so the only contract worth pinning is
/// the request the driver triggers and the SnackBar that tells them it landed —
/// or did not.
void main() {
  late MockSafetyRepository repo;

  setUp(() {
    repo = MockSafetyRepository();
  });

  Future<void> pumpSafety(
    WidgetTester tester, {
    GeoPoint? position = const GeoPoint(9.9333, -84.0833),
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          safetyRepositoryProvider.overrideWith((ref) => repo),
          lastPositionProvider.overrideWith((ref) => position),
        ],
        child: const MaterialApp(home: SafetyScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('SOS sends the last known position and acks', (tester) async {
    when(() => repo.sendSos(
          lat: any(named: 'lat'),
          lng: any(named: 'lng'),
        )).thenAnswer((_) async {});

    await pumpSafety(tester);
    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pumpAndSettle();

    verify(() => repo.sendSos(lat: 9.9333, lng: -84.0833)).called(1);
    expect(
      find.text('SOS sent — our support team has been alerted.'),
      findsOneWidget,
    );
  });

  testWidgets('SOS without a known position does not call the API',
      (tester) async {
    await pumpSafety(tester, position: null);
    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pumpAndSettle();

    verifyNever(() => repo.sendSos(
          lat: any(named: 'lat'),
          lng: any(named: 'lng'),
        ));
    expect(
      find.text('Location unavailable — cannot send SOS.'),
      findsOneWidget,
    );
  });

  testWidgets('a failed SOS surfaces an error snackbar', (tester) async {
    when(() => repo.sendSos(
          lat: any(named: 'lat'),
          lng: any(named: 'lng'),
        )).thenThrow(Exception('offline'));

    await pumpSafety(tester);
    await tester.tap(find.byKey(const Key('sos-button')));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not send SOS. Please call emergency services.'),
      findsOneWidget,
    );
    expect(
      find.text('SOS sent — our support team has been alerted.'),
      findsNothing,
    );
  });

  testWidgets('feedback dialog posts app_issue and closes', (tester) async {
    when(() => repo.sendFeedback(
          type: any(named: 'type'),
          message: any(named: 'message'),
        )).thenAnswer((_) async {});

    await pumpSafety(tester);
    await tester.tap(find.byKey(const Key('feedback-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('feedback-input')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('feedback-input')),
      'The app crashed mid-trip',
    );
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();

    verify(() => repo.sendFeedback(
          type: 'app_issue',
          message: 'The app crashed mid-trip',
        )).called(1);
    expect(find.byKey(const Key('feedback-input')), findsNothing);
    expect(find.text('Thanks — feedback sent.'), findsOneWidget);
  });

  testWidgets('an empty feedback message sends nothing', (tester) async {
    await pumpSafety(tester);
    await tester.tap(find.byKey(const Key('feedback-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();

    verifyNever(() => repo.sendFeedback(
          type: any(named: 'type'),
          message: any(named: 'message'),
        ));
    expect(find.byKey(const Key('feedback-input')), findsNothing);
  });

  testWidgets('a failed feedback surfaces an error snackbar', (tester) async {
    when(() => repo.sendFeedback(
          type: any(named: 'type'),
          message: any(named: 'message'),
        )).thenThrow(Exception('offline'));

    await pumpSafety(tester);
    await tester.tap(find.byKey(const Key('feedback-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('feedback-input')),
      'Something broke',
    );
    await tester.tap(find.byKey(const Key('feedback-send')));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not send feedback. Please try again.'),
      findsOneWidget,
    );
  });
}
