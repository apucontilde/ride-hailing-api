import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/presentation/home_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}
class MockWebSocketService extends Mock implements WebSocketService {}

class _Stub extends StatelessWidget {
  const _Stub(this.label);

  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Center(child: Text(label)));
}

void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late MockWebSocketService mockWebSocketService;
  late ProviderContainer container;

  /// The real `GET /rider/me` payload, so the header renders what production
  /// renders rather than a hand-built state. `photo_url` is empty on purpose:
  /// `flutter_test` has no network, and a real `NetworkImage` would fail the
  /// suite asynchronously.
  const riderMeData = {
    'user': {'id': 'user-1', 'email': 'ana@example.com'},
    'rider': {
      'user_id': 'user-1',
      'first_name': 'Ana',
      'last_name': 'Rojas',
      'status': 'idle',
      'photo_url': '',
    },
  };

  setUp(() async {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockWebSocketService = MockWebSocketService();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => 'token');
    // No stored refresh token, so logout() skips `POST /auth/logout` and only the
    // local cleanup path runs.
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
        statusCode: 200,
        data: riderMeData,
      ),
    );

    // All three overrides are required: `logout()` reaches `authProvider`, which
    // reads storage and the socket and throws without them.
    container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    addTearDown(container.dispose);
    await container.read(authProvider.notifier).checkAuth();
  });

  /// A **bespoke** router, deliberately not `routerProvider`: the app router
  /// starts at `/splash` and its redirect passes splash through, so frame 1 is
  /// `SplashScreen`, which awaits `checkAuth()` and a current-ride check before
  /// it navigates anywhere. Reaching `/home` through the real router would need
  /// an authenticated-state override before the drawer was ever on screen.
  Future<void> pumpHome(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/profile', builder: (_, _) => const _Stub('Profile Page')),
        GoRoute(path: '/history', builder: (_, _) => const _Stub('History Page')),
        GoRoute(path: '/payment', builder: (_, _) => const _Stub('Payment Page')),
        GoRoute(path: '/security', builder: (_, _) => const _Stub('Security Page')),
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
  }

  Future<void> openSidebar(WidgetTester tester) async {
    await tester.tap(find.byType(AppSidebarToggleButton));
    await tester.pumpAndSettle();
  }

  group('rider sidebar structure', () {
    testWidgets('opens from the shared toggle button', (tester) async {
      await pumpHome(tester);

      expect(find.byType(AppSidebarToggleButton), findsOneWidget);
      expect(find.byType(AppSidebar), findsNothing);

      await openSidebar(tester);
      expect(find.byType(AppSidebar), findsOneWidget);
    });

    testWidgets('drawer header shows the signed-in rider, not a literal', (tester) async {
      // Migrated from `home_screen_test.dart`, where it pumped `HomeScreen` with
      // no router at all — that worked only while the drawer had no navigation.
      // The `find.byIcon(Icons.menu)` tap is kept verbatim: it survives because
      // `AppSidebarToggleButton` renders `Icons.menu` by default.
      await pumpHome(tester);

      await tester.tap(find.byIcon(Icons.menu));
      await tester.pumpAndSettle();

      expect(find.text('Ana Rojas'), findsOneWidget);
      expect(find.text('ana@example.com'), findsOneWidget);
      // A historical placeholder: nothing in either app would ever pass 'Rider'
      // as a status, so this stays green without any mechanism behind it.
      expect(find.text('Rider'), findsNothing);
    });

    testWidgets('the four section headings appear in enum order', (tester) async {
      await pumpHome(tester);
      await openSidebar(tester);

      // Read back in paint order: four independent `findsOneWidget`s would not
      // catch SAFETY rendering above ACTIVITY.
      const headings = ['ACCOUNT', 'ACTIVITY', 'SAFETY', 'APP'];
      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .where((d) => headings.contains(d))
          .toList();
      expect(rendered, headings);
    });

    testWidgets('every destination is findable by its sidebar key', (tester) async {
      await pumpHome(tester);
      await openSidebar(tester);

      for (final id in ['profile', 'ride-history', 'payment', 'security', 'settings']) {
        expect(find.byKey(Key('sidebar-item-$id')), findsOneWidget, reason: id);
      }
    });

    testWidgets('the sign-out footer row is present', (tester) async {
      // Sign-out used to cost three taps: drawer → Settings → Sign out.
      await pumpHome(tester);
      await openSidebar(tester);

      expect(find.byKey(const Key('sidebar-sign-out')), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
    });

    testWidgets('shows no status dot and no rating, unlike the driver', (tester) async {
      await pumpHome(tester);
      await openSidebar(tester);

      expect(find.byKey(const Key('status-dot')), findsNothing);
      expect(find.byIcon(Icons.star), findsNothing);
      // The rider's second line is the email, not a status.
      expect(find.text('ana@example.com'), findsOneWidget);
    });
  });

  group('rider sidebar navigation', () {
    testWidgets('every item routes to its own destination', (tester) async {
      // Coverage the app has never had: nothing asserted that a drawer item
      // actually navigated anywhere.
      const cases = <String, String>{
        'profile': 'Profile Page',
        'ride-history': 'History Page',
        'payment': 'Payment Page',
        'security': 'Security Page',
        'settings': 'Settings Page',
      };
      for (final entry in cases.entries) {
        await pumpHome(tester);
        await openSidebar(tester);

        await tester.tap(find.byKey(Key('sidebar-item-${entry.key}')));
        await tester.pumpAndSettle();

        expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      }
    });

    testWidgets('tapping the header routes to /profile with the drawer closed', (tester) async {
      await pumpHome(tester);
      await openSidebar(tester);

      await tester.tap(find.text('Ana Rojas'));
      await tester.pumpAndSettle();

      expect(find.text('Profile Page'), findsOneWidget);
      // Pop-then-push: the old `GestureDetector` header had to get this order
      // right by hand, and nothing asserted it. Pushing first would leave the
      // drawer open on top of /profile.
      expect(find.byKey(const Key('sidebar-item-profile')), findsNothing);
      expect(find.byType(AppSidebar), findsNothing);
    });

    testWidgets('a destination row also closes the drawer before pushing', (tester) async {
      await pumpHome(tester);
      await openSidebar(tester);

      await tester.tap(find.byKey(const Key('sidebar-item-settings')));
      await tester.pumpAndSettle();

      expect(find.text('Settings Page'), findsOneWidget);
      expect(find.byType(AppSidebar), findsNothing);
    });
  });

  group('rider sidebar sign-out', () {
    testWidgets('confirming clears the session and returns to /login', (tester) async {
      // The pre-condition is asserted, not assumed: `riderProfileProvider` is a
      // `StateProvider<RiderProfile?>` defaulting to null, so in a container that
      // never seeded a profile the `isNull` assertion below would pass even with
      // `onLoggedOut` deleted. Here the real bootstrap seeded it.
      expect(container.read(riderProfileProvider), isNotNull);

      await pumpHome(tester);
      await openSidebar(tester);

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();
      expect(find.text('Sign out?'), findsOneWidget);
      expect(
        find.text('You will need to log in again to request rides.'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await tester.pumpAndSettle();

      expect(find.text('Log In'), findsOneWidget);
      expect(container.read(riderProfileProvider), isNull);
      verify(() => mockWebSocketService.disconnect()).called(1);
      verify(() => mockStorage.clearTokens()).called(1);
    });

    testWidgets('cancelling keeps the session and stays on /home', (tester) async {
      await pumpHome(tester);
      await openSidebar(tester);

      await tester.tap(find.byKey(const Key('sidebar-sign-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(container.read(riderProfileProvider), isNotNull);
      verifyNever(() => mockWebSocketService.disconnect());
      verifyNever(() => mockStorage.clearTokens());
      expect(find.text('Log In'), findsNothing);
    });
  });
}
