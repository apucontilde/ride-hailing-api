import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/api_exceptions.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/presentation/profile_screen.dart';

class MockAuthStorage extends Mock implements AuthStorage {}
class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}
class MockWebSocketService extends Mock implements WebSocketService {}

void main() {
  late MockAuthStorage mockStorage;
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late MockWebSocketService mockWebSocketService;
  late ProviderContainer container;

  /// The real `GET /rider/me` payload: name/photo on `rider`, email/phone on
  /// `user`. `photo_url` is empty on purpose — `flutter_test` has no network,
  /// and a real `NetworkImage` would fail the test asynchronously. The
  /// photo-bearing path is covered by `RiderProfile`'s own unit test and by
  /// the notifier test.
  const riderMeData = {
    'user': {
      'id': 'user-1',
      'email': 'ana@example.com',
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

  setUp(() async {
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockWebSocketService = MockWebSocketService();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockStorage.getAccessToken()).thenAnswer((_) async => 'token');
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
        Response(
          requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
          statusCode: 200,
          data: riderMeData,
        ));
    container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    addTearDown(container.dispose);
    // Run the real auth bootstrap so the screen sees a genuinely seeded
    // session rather than a hand-built state.
    await container.read(authProvider.notifier).checkAuth();
  });

  Future<void> pumpProfile(WidgetTester tester) async {
    // Tall enough that the whole ListView lays out, so a test never has to
    // scroll to reach a tile.
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/profile',
      routes: [
        GoRoute(path: '/profile', builder: (_, _) => const ProfileScreen()),
        GoRoute(
          path: '/settings',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('Settings Page'))),
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

  group('ProfileScreen', () {
    testWidgets('renders the API values, not literals', (tester) async {
      await pumpProfile(tester);

      expect(find.text('Ana Rojas'), findsOneWidget);
      expect(find.text('ana@example.com'), findsOneWidget);
      expect(find.text('+5065551234'), findsOneWidget);
      expect(find.text('idle'), findsOneWidget);
      // Initials of the fetched name, not a generic person icon.
      expect(find.text('AR'), findsOneWidget);
      // Every placeholder the screen used to hardcode is gone.
      expect(find.text('Rider'), findsNothing);
      expect(find.text('rider@example.com'), findsNothing);
      expect(find.text('Not set'), findsNothing);
    });

    testWidgets('prefills the form from the cached profile',
        (tester) async {
      await pumpProfile(tester);

      expect(field(tester, 'First name').controller?.text, 'Ana');
      expect(field(tester, 'Last name').controller?.text, 'Rojas');
      expect(field(tester, 'Phone').controller?.text, '+5065551234');
    });

    testWidgets('falls back to the email when the rider set no name',
        (tester) async {
      when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
          Response(
            requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
            statusCode: 200,
            data: const {
              'user': {'id': 'user-1', 'email': 'ana@example.com'},
              // `riders.first_name` is NOT NULL DEFAULT '' — the untouched
              // account really does answer with empty strings.
              'rider': {
                'user_id': 'user-1',
                'first_name': '',
                'last_name': '',
                'photo_url': '',
                'status': 'idle',
              },
            },
          ));
      await container.read(authProvider.notifier).refreshProfile();

      await pumpProfile(tester);

      // The email becomes the display name rather than an invented label, and
      // is therefore not printed twice.
      expect(find.text('ana@example.com'), findsOneWidget);
      expect(find.text('Rider'), findsNothing);
      // An untouched account must not be dressed up with placeholder values.
      expect(find.textContaining('Not set'), findsNothing);
    });

    testWidgets('validates the name and phone fields', (tester) async {
      await pumpProfile(tester);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'First name'), 'A');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Phone'), 'not-a-phone');
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Name must be at least 2 characters'), findsOneWidget);
      expect(find.text('Enter a valid phone number'), findsOneWidget);
      verifyNever(() => mockDio.put(any(), data: any(named: 'data')));
    });

    testWidgets('saves the edit and shows the confirmation', (tester) async {
      when(() => mockDio.put(any(), data: any(named: 'data')))
          .thenAnswer((_) async => Response(
                requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
                statusCode: 200,
                data: {
                  'rider': {
                    'user_id': 'user-1',
                    'first_name': 'Ana',
                    'last_name': 'Updated',
                    'photo_url': '',
                    'status': 'idle',
                  },
                },
              ));
      // `PUT /rider/me` answers `{rider}` only, so the phone edit is confirmed
      // by the follow-up `GET /rider/me` the notifier issues.
      when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
          Response(
            requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
            statusCode: 200,
            data: const {
              'user': {
                'id': 'user-1',
                'email': 'ana@example.com',
                'phone': '+5065559999',
              },
              'rider': {
                'user_id': 'user-1',
                'first_name': 'Ana',
                'last_name': 'Updated',
                'photo_url': '',
                'status': 'idle',
              },
            },
          ));

      await pumpProfile(tester);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Last name'), 'Updated');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Phone'), '+5065559999');
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(find.text('Profile saved'), findsOneWidget);
      expect(find.text('+5065559999'), findsOneWidget);
      expect(container.read(riderProfileProvider)?.lastName, 'Updated');
    });

    testWidgets('shows the mapped error and leaves the form in place',
        (tester) async {
      when(() => mockDio.put(any(), data: any(named: 'data')))
          .thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
        response: Response(
          requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
          statusCode: 422,
          data: {
            'error': {
              'code': 'VALIDATION_ERROR',
              'message': 'first_name is required',
            },
          },
        ),
        error: mapStatusCodeToException(422, 'first_name is required'),
        message: 'This exception was thrown because the response has a '
            'status code of 422 ...',
      ));

      await pumpProfile(tester);

      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-error')), findsOneWidget);
      expect(find.text('first_name is required'), findsOneWidget);
      expect(find.text('Profile saved'), findsNothing);
      expect(find.text('Ana Rojas'), findsOneWidget);
    });

    testWidgets('disables the save button while saving', (tester) async {
      when(() => mockDio.put(any(), data: any(named: 'data')))
          .thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return Response(
          requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
          statusCode: 200,
          data: {
            'rider': {
              'user_id': 'user-1',
              'first_name': 'Ana',
              'last_name': 'Updated',
              'photo_url': '',
            },
          },
        );
      });
      when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
          Response(
            requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
            statusCode: 200,
            data: const {
              'user': {'id': 'user-1', 'email': 'ana@example.com'},
              'rider': {
                'user_id': 'user-1',
                'first_name': 'Ana',
                'last_name': 'Updated',
              },
            },
          ));

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

    testWidgets('Settings tile routes to /settings', (tester) async {
      await pumpProfile(tester);

      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();

      expect(find.text('Settings Page'), findsOneWidget);
    });
  });
}
