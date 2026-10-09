import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/features/driver/model/driver_profile.dart';
import 'package:driver_app/features/profile/presentation/profile_screen.dart';

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

/// The first coverage `profile_screen.dart` has ever had — driver known bug #4.
///
/// Because nothing guarded it before, this suite is also where the header's own
/// logic gets its first assertions: the two-letter initials, the `'Driver'`
/// display-name fallback, and the `onboardingStatus` chip.
void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late ProviderContainer container;

  const driver = DriverProfile(
    userId: 'd1',
    firstName: 'Ava',
    lastName: 'Lopez',
    photoUrl: '',
    status: 'online',
    onboardingStatus: 'verified',
    ratingSummary: '4.8',
  );

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
  });

  /// [seed] is pinned through the provider because `ProfileNotifier` reads it in
  /// its constructor; a container that omits it renders the spinner forever.
  ProviderContainer buildContainer({DriverProfile seed = driver}) {
    final c = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        driverProfileProvider.overrideWith((ref) => seed),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> pumpProfile(
    WidgetTester tester, {
    DriverProfile seed = driver,
  }) async {
    container = buildContainer(seed: seed);
    // Tall enough that the whole ListView lays out, so a test never has to scroll
    // to reach a tile.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        // Body-only since bug #10, so the test hosts it in a Scaffold the way
        // `DriverShell` does in the app.
        GoRoute(
          path: '/profile',
          builder: (_, _) => const Scaffold(body: ProfileScreen()),
        ),
        GoRoute(
          path: '/vehicle',
          builder: (_, _) => const Scaffold(body: Text('Vehicle Page')),
        ),
        GoRoute(
          path: '/rides-history',
          builder: (_, _) => const Scaffold(body: Text('Rides History Page')),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, _) => const Scaffold(body: Text('Settings Page')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextFormField field(WidgetTester tester, String label) =>
      tester.widget<TextFormField>(find.widgetWithText(TextFormField, label));

  group('ProfileScreen header', () {
    testWidgets('maps the API rating to the app-owned label', (tester) async {
      await pumpProfile(tester);

      // `ratingSummaryLabel` is driver-owned: the shared header renders an
      // opaque string, and the star formatting is this screen's decision.
      expect(find.text('★ 4.8'), findsOneWidget);
    });

    testWidgets(
      "a nameless driver falls back to 'Driver', 'New driver' and the pending chip",
      (tester) async {
        // Known bug #3 means this is the common path for a fresh driver, not an
        // edge case: onboarding never `PUT`s /driver/me.
        await pumpProfile(tester, seed: const DriverProfile(userId: 'd2'));

        // All three strings are app-owned decisions fed to the shared header.
        expect(find.text('Driver'), findsOneWidget);
        expect(find.text('New driver'), findsOneWidget);
        expect(find.text('Onboarding pending'), findsOneWidget);
      },
    );
  });

  group('ProfileScreen form', () {
    testWidgets('prefills first and last name and leaves the phone empty', (
      tester,
    ) async {
      await pumpProfile(tester);

      expect(field(tester, 'First name').controller?.text, 'Ava');
      expect(field(tester, 'Last name').controller?.text, 'Lopez');
      // The driver's distinguishing seed: the rider pre-fills the phone from
      // `authProvider`, the driver has never done so, and starting to would make
      // a first/last-only save write a phone this app never wrote.
      expect(field(tester, 'Phone').controller?.text, '');
    });

    testWidgets('saves a sparse body and keeps the phone field empty', (
      tester,
    ) async {
      when(
        () => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
          statusCode: 200,
          data: {
            'driver': {
              'user_id': 'd1',
              'first_name': 'Ava',
              'last_name': 'Updated',
              'photo_url': '',
              'status': 'online',
              'onboarding_status': 'verified',
            },
          },
        ),
      );

      await pumpProfile(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Last name'),
        'Updated',
      );
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      // The driver's notifier sends only the fields it is given — unlike the
      // rider's, which sends first/last/photo unconditionally because its handler
      // assigns them all. Sharing the form widget must not reconcile that.
      final captured = verify(
        () =>
            mockDio.put(ApiEndpoints.driverMe, data: captureAny(named: 'data')),
      ).captured;
      expect(captured.single, {'first_name': 'Ava', 'last_name': 'Updated'});
      expect(captured.single, isNot(contains('phone')));

      expect(find.text('Profile saved'), findsOneWidget);
      expect(field(tester, 'Phone').controller?.text, '');
      expect(field(tester, 'Last name').controller?.text, 'Updated');
    });

    testWidgets('an empty phone never blocks the save', (tester) async {
      // A mandatory phone would make this the driver's only save path unreachable.
      when(
        () => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
          statusCode: 200,
          data: {
            'driver': {
              'user_id': 'd1',
              'first_name': 'Ava',
              'last_name': 'Lopez',
            },
          },
        ),
      );

      await pumpProfile(tester);
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Phone number is required'), findsNothing);
      expect(find.text('Profile saved'), findsOneWidget);
    });

    testWidgets('validates a malformed phone and never calls the API', (
      tester,
    ) async {
      await pumpProfile(tester);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Phone'),
        'not-a-phone',
      );
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Enter a valid phone number'), findsOneWidget);
      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
    });

    testWidgets('shows the mapped error under the profile-error key', (
      tester,
    ) async {
      when(
        () => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
          response: Response(
            requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
            statusCode: 422,
            data: {
              'error': {
                'code': 'VALIDATION_ERROR',
                'message': 'first_name is required',
              },
            },
          ),
          error: mapStatusCodeToException(422, 'first_name is required'),
          message: 'status code of 422',
        ),
      );

      await pumpProfile(tester);
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      // `Key('profile-error')` is NEW here, not preserved: the driver's error
      // `Text` carried no key before, unlike the rider's.
      expect(find.byKey(const Key('profile-error')), findsOneWidget);
      expect(find.text('first_name is required'), findsOneWidget);
      expect(find.text('Profile saved'), findsNothing);
    });

    testWidgets('disables the save button while saving', (tester) async {
      when(
        () => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')),
      ).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return Response(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
          statusCode: 200,
          data: {
            'driver': {
              'user_id': 'd1',
              'first_name': 'Ava',
              'last_name': 'Lopez',
            },
          },
        );
      });

      await pumpProfile(tester);
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pump();

      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('profile-save-button')))
            .onPressed,
        isNull,
      );
      expect(find.byType(CircularProgressIndicator), findsWidgets);

      await tester.pumpAndSettle();
    });
  });

  group('ProfileScreen menu card', () {
    testWidgets('rows route to their destinations', (tester) async {
      await pumpProfile(tester);

      await tester.tap(find.byKey(const Key('nav-link-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Settings Page'), findsOneWidget);
    });

    testWidgets('the ride history row carries the sidebar label', (
      tester,
    ) async {
      await pumpProfile(tester);

      // The card used to say 'Ride history' while the drawer said 'Ride history &
      // earnings'. Both now read the same list, so they cannot disagree.
      expect(find.text('Ride history & earnings'), findsOneWidget);
      expect(find.text('Ride history'), findsNothing);
    });

    testWidgets('the new Home row is present as a shortcut', (tester) async {
      await pumpProfile(tester);

      // Fed from the same list minus `profile`, so the Home row appears here
      // automatically and routes via the card's `context.go`.
      expect(find.byKey(const Key('nav-link-home')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('nav-link-home')),
          matching: find.text('Home'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('no /vehicle row while the vehicle backend is a stub', (
      tester,
    ) async {
      await pumpProfile(tester);

      // The other half of the "neither surface links to /vehicle" assertion —
      // this card row was the ONLY `context.push('/vehicle')` in the app, so
      // after this stage the screen is reachable only by deep link.
      expect(find.byKey(const Key('nav-link-vehicle')), findsNothing);
      expect(find.text('Vehicle & documents'), findsNothing);
    });
  });
}
