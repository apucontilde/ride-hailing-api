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

class MockApiClient extends Mock implements ApiClient {}

class MockDio extends Mock implements Dio {}

class MockAuthStorage extends Mock implements AuthStorage {}

class MockWebSocketService extends Mock implements WebSocketService {}

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

class _Stub extends StatelessWidget {
  const _Stub(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(label)));
}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late MockAuthStorage mockStorage;
  late MockWebSocketService mockWebSocketService;

  /// Online, photoless, rated: exercises the status dot, the initials fallback
  /// and the rating row in one profile. `photoUrl: ''` is the shape
  /// `DriverProfile.fromJson` actually produces for a driver with no photo.
  const profile = DriverProfile(
    userId: 'd1',
    firstName: 'Ada',
    lastName: 'Lovelace',
    photoUrl: '',
    status: 'online',
    onboardingStatus: 'verified',
    ratingSummary: '4.9',
  );

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockStorage = MockAuthStorage();
    mockWebSocketService = MockWebSocketService();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => 'token');
    // No stored refresh token, so logout() skips `POST /auth/logout` and only the
    // local cleanup path runs.
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    when(() => mockDio.get(ApiEndpoints.driverRidesCurrent)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverRidesCurrent),
        statusCode: 200,
        data: {'ride': null},
      ),
    );
  });

  /// A ride-state notifier per container.
  ///
  /// Sharing one instance across containers is not safe: disposing the first
  /// container disposes the notifier, and every later container's teardown then
  /// fails with "Tried to use RideStateNotifier after `dispose` was called".
  RideStateNotifier freshRideState() {
    final mockDriverWs = MockDriverWebSocketService();
    when(() => mockDriverWs.events).thenAnswer((_) => const Stream<WsEvent>.empty());
    return RideStateNotifier(mockDriverWs, apiClient: mockApiClient);
  }

  /// Everything `HomeScreen` needs that is not auth: no geolocator channel, no
  /// launch restore, no trip tiles.
  List<Override> baseOverrides() => [
        apiClientProvider.overrideWithValue(mockApiClient),
        rideStateProvider.overrideWith((ref) => freshRideState()),
        appPermissionProvider
            .overrideWith((ref) => const AppPermissionState(granted: true)),
        locationServiceProvider.overrideWith(
          (ref) => FakeLocationService(
            apiClient: mockApiClient,
            availabilityNotifier: ref.read(availabilityProvider.notifier),
          ),
        ),
      ];

  /// Container for the structural and navigation cases, where the profile just
  /// has to be there.
  ProviderContainer profileContainer() {
    final container = ProviderContainer(
      overrides: [
        ...baseOverrides(),
        driverProfileProvider.overrideWith((ref) => profile),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Container for the sign-out case.
  ///
  /// Two differences from [profileContainer], both deliberate:
  /// * the profile is **seeded** through the notifier rather than pinned with an
  ///   override, so `onLoggedOut` can actually null it;
  /// * the auth overrides are present, because `logout()` reads storage and the
  ///   socket and throws without them.
  ///
  /// Omitting the override entirely would be just as useless as pinning it:
  /// `driverProfileProvider` is a `StateProvider<DriverProfile?>` defaulting to
  /// null, so the post-sign-out `isNull` assertion would pass even with
  /// `onLoggedOut` deleted.
  ProviderContainer signOutContainer() {
    final container = ProviderContainer(
      overrides: [
        ...baseOverrides(),
        authStorageProvider.overrideWithValue(mockStorage),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    addTearDown(container.dispose);
    container.read(driverProfileProvider.notifier).state = profile;
    return container;
  }

  /// A **bespoke** router, not `routerProvider` (the app router starts at
  /// `/splash`). This is the existing `home_screen_test.dart` harness extended
  /// with a stub for every route the sidebar can push, plus `/login` for
  /// sign-out — without them each tap throws instead of navigating.
  Future<void> pumpHome(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/profile', builder: (_, _) => const _Stub('Profile Page')),
        GoRoute(path: '/vehicle', builder: (_, _) => const _Stub('Vehicle Page')),
        GoRoute(
          path: '/rides-history',
          builder: (_, _) => const _Stub('Rides History Page'),
        ),
        GoRoute(path: '/settings', builder: (_, _) => const _Stub('Settings Page')),
        GoRoute(path: '/login', builder: (_, _) => const _Stub('Log In')),
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

  Future<void> openSidebar(WidgetTester tester) async {
    await tester.tap(find.byType(AppSidebarToggleButton));
    await tester.pumpAndSettle();
  }

  /// The AppBar title `Row` keeps rendering the name and the status while the
  /// drawer is open, so a bare `find.text` matches twice. Scope to the *widget*:
  /// `AppSidebarAccount` is a plain value object and never becomes an `Element`.
  Finder inHeader(Finder matching) => find.descendant(
        of: find.byType(AppSidebarHeader),
        matching: matching,
      );

  group('driver sidebar structure', () {
    testWidgets('opens from the shared toggle button in the AppBar', (tester) async {
      await pumpHome(tester, profileContainer());

      expect(find.byType(AppSidebarToggleButton), findsOneWidget);
      expect(find.byType(AppSidebar), findsNothing);

      await openSidebar(tester);
      expect(find.byType(AppSidebar), findsOneWidget);
    });

    testWidgets('the section headings appear in enum order, and SAFETY is absent', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      // The driver has no payment or security destination, so its sidebar renders
      // three of the four headings from the same widget and the same enum order.
      // Read back in paint order: independent `findsOneWidget`s would not catch
      // APP rendering above ACTIVITY.
      const all = ['ACCOUNT', 'ACTIVITY', 'SAFETY', 'APP'];
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => all.contains(d))
          .toList();
      expect(rendered, ['ACCOUNT', 'ACTIVITY', 'APP']);
      expect(find.text('SAFETY'), findsNothing);
    });

    testWidgets('every destination is findable by its sidebar key', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      for (final id in ['profile', 'ride-history', 'settings']) {
        expect(find.byKey(Key('sidebar-item-$id')), findsOneWidget, reason: id);
      }
    });

    testWidgets('the overridden label renders and the others stay canonical', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      // Item rows are siblings of the header inside the scroller, so these are
      // unscoped — and unique, because the AppBar title renders the driver's
      // name, never a destination label.
      expect(find.text('Ride history & earnings'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
      // The canonical label must not leak through the override.
      expect(find.text('Ride history'), findsNothing);
    });

    testWidgets('no /vehicle row while the vehicle backend is a stub', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      // Half of the "neither surface links to /vehicle" assertion; the profile
      // card's half lives in `profile_screen_test.dart`. Together they stop a
      // later change re-adding one side and silently desyncing the other.
      expect(find.byKey(const Key('sidebar-item-vehicle')), findsNothing);
    });

    testWidgets('the sign-out footer row is present', (tester) async {
      // Sign-out used to cost two taps: drawer → Settings → Sign out.
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      expect(find.byKey(const Key('sidebar-sign-out')), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
      // The footer is pinned below the scroller, not part of the header block.
      expect(inHeader(find.text('Sign out')), findsNothing);
    });
  });

  group('driver sidebar header', () {
    testWidgets('shows the name and the status on the dot row', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      expect(inHeader(find.text('Ada Lovelace')), findsOneWidget);
      expect(inHeader(find.text('online')), findsOneWidget);
      expect(inHeader(find.byKey(const Key('status-dot'))), findsOneWidget);

      final dot = tester.widget<Container>(inHeader(find.byKey(const Key('status-dot'))));
      expect((dot.decoration! as BoxDecoration).color, Colors.green);
    });

    testWidgets("the old 'Status: …' email-slot string is gone from the header", (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      // The home screen's dev tile still prints 'Status: online', so this is
      // scoped: what must disappear is the header's abuse of the email slot.
      expect(inHeader(find.text('Status: online')), findsNothing);
      expect(inHeader(find.text('Status: unknown')), findsNothing);
      // And no email line was substituted for it.
      expect(inHeader(find.textContaining('@')), findsNothing);
    });

    testWidgets('honours photoUrl by falling back to initials when it is blank', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      // `DriverProfile.photoUrl` is `''` here, which is what the API returns for a
      // driver with no photo. `NetworkImage('')` would paint a red error box.
      expect(inHeader(find.text('AL')), findsOneWidget);
      final avatar = tester.widget<CircleAvatar>(
        find.descendant(of: find.byType(AppSidebarHeader), matching: find.byType(CircleAvatar)),
      );
      expect(avatar.backgroundImage, isNull);
    });

    testWidgets('shows the rating row', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      expect(inHeader(find.text('★ 4.9')), findsOneWidget);
    });

    testWidgets("a nameless driver shows 'Driver' and a 'D' avatar", (tester) async {
      // Known bug #3: onboarding never `PUT`s /driver/me, so a fresh driver's
      // fullName really is empty. The `'Driver'` fallback is app-side and the
      // shared rule derives the initial from it.
      final container = ProviderContainer(
        overrides: [
          ...baseOverrides(),
          driverProfileProvider.overrideWith((ref) => const DriverProfile(userId: 'd2')),
        ],
      );
      addTearDown(container.dispose);
      await pumpHome(tester, container);
      await openSidebar(tester);

      expect(inHeader(find.text('Driver')), findsOneWidget);
      expect(inHeader(find.text('D')), findsOneWidget);
    });
  });

  group('driver sidebar navigation', () {
    testWidgets('every item routes to its own destination', (tester) async {
      const cases = <String, String>{
        'profile': 'Profile Page',
        'ride-history': 'Rides History Page',
        'settings': 'Settings Page',
      };
      for (final entry in cases.entries) {
        await pumpHome(tester, profileContainer());
        await openSidebar(tester);

        await tester.tap(find.byKey(Key('sidebar-item-${entry.key}')));
        await tester.pumpAndSettle();

        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      }
    });

    testWidgets('tapping the header navigates to /profile — the behaviour the driver never had', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      // The old header had no details affordance and no wrapping tap target, so
      // tapping it did nothing at all.
      await tester.tap(inHeader(find.text('Ada Lovelace')));
      await tester.pumpAndSettle();

      expect(find.text('Profile Page'), findsOneWidget);
      // …and it lands there with the drawer closed: pop-then-push is what makes
      // the "same widget as the rider" claim true at both call sites.
      expect(find.byType(AppSidebar), findsNothing);
      expect(find.byKey(const Key('sidebar-item-profile')), findsNothing);
    });

    testWidgets('a destination row also closes the drawer before pushing', (tester) async {
      await pumpHome(tester, profileContainer());
      await openSidebar(tester);

      await tester.tap(find.byKey(const Key('sidebar-item-settings')));
      await tester.pumpAndSettle();

      expect(find.text('Settings Page'), findsOneWidget);
      expect(find.byType(AppSidebar), findsNothing);
    });
  });

  group('driver sidebar sign-out', () {
    testWidgets('confirming clears the session, the profile cache, and returns to /login', (tester) async {
      final container = signOutContainer();
      // Asserted pre-condition: without a seeded profile this test cannot fail.
      expect(container.read(driverProfileProvider), isNotNull);

      await pumpHome(tester, container);
      await openSidebar(tester);

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsOneWidget);
      expect(
        find.text('You will need to log in again to accept ride requests.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Log In'), findsOneWidget);
      expect(container.read(driverProfileProvider), isNull);
      verify(() => mockWebSocketService.disconnect()).called(1);
      verify(() => mockStorage.clearTokens()).called(1);
    });

    testWidgets('cancelling keeps the session and stays on /home', (tester) async {
      final container = signOutContainer();
      await pumpHome(tester, container);
      await openSidebar(tester);

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(container.read(driverProfileProvider), isNotNull);
      verifyNever(() => mockWebSocketService.disconnect());
      verifyNever(() => mockStorage.clearTokens());
      expect(find.text('Log In'), findsNothing);
    });
  });
}
