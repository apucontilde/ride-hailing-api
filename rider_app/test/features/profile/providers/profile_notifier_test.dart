import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:mocktail/mocktail.dart';
import 'package:rider_app/core/auth/auth_provider.dart';
import 'package:rider_app/core/auth/auth_storage.dart';
import 'package:rider_app/core/api/api_client.dart';
import 'package:rider_app/core/api/api_exceptions.dart';
import 'package:rider_app/core/api/endpoints.dart';
import 'package:rider_app/core/network/websocket_service.dart';
import 'package:rider_app/features/home/model/rider_profile.dart';
import 'package:rider_app/features/profile/providers/profile_notifier.dart';

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

  /// The profile the auth bootstrap leaves in the cache.
  const cached = RiderProfile(
    userId: 'user-1',
    firstName: 'Ana',
    lastName: 'Rojas',
    photoUrl: 'https://cdn.example.com/ana.png',
  );

  /// The body `PUT /rider/me` was last called with, asserted after the fact so
  /// a mismatch reads as a diff instead of a swallowed exception.
  Map<String, dynamic>? sentBody;

  setUp(() {
    sentBody = null;
    mockStorage = MockAuthStorage();
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    mockWebSocketService = MockWebSocketService();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    when(() => mockWebSocketService.connect(token: any(named: 'token')))
        .thenAnswer((_) async {});
    when(() => mockWebSocketService.disconnect()).thenAnswer((_) async {});
    when(() => mockStorage.getRefreshToken()).thenAnswer((_) async => null);
    when(() => mockStorage.clearTokens()).thenAnswer((_) async {});
    container = ProviderContainer(
      overrides: [
        authStorageProvider.overrideWithValue(mockStorage),
        apiClientProvider.overrideWithValue(mockApiClient),
        webSocketServiceProvider.overrideWithValue(mockWebSocketService),
      ],
    );
    container.read(riderProfileProvider.notifier).state = cached;
    addTearDown(container.dispose);
  });

  /// `PUT /rider/me` answers `{rider}` only — no `user`, no `phone`.
  void stubPut({String lastName = 'Updated'}) {
    when(() => mockDio.put(any(), data: any(named: 'data')))
        .thenAnswer((invocation) async {
      sentBody =
          invocation.namedArguments[#data] as Map<String, dynamic>;
      return Response(
        requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
        statusCode: 200,
        data: {
          'rider': {
            'user_id': 'user-1',
            'first_name': 'Ana',
            'last_name': lastName,
            'photo_url': 'https://cdn.example.com/ana.png',
            'status': 'idle',
          },
        },
      );
    });
  }

  /// The `GET /rider/me` re-read that makes a phone edit authoritative.
  void stubGet({String phone = '+5065559999', String lastName = 'Updated'}) {
    when(() => mockDio.get(ApiEndpoints.riderMe)).thenAnswer((_) async =>
        Response(
          requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
          statusCode: 200,
          data: {
            'user': {
              'id': 'user-1',
              'email': 'ana@example.com',
              'phone': phone,
            },
            'rider': {
              'user_id': 'user-1',
              'first_name': 'Ana',
              'last_name': lastName,
              'photo_url': 'https://cdn.example.com/ana.png',
              'status': 'idle',
            },
          },
        ));
  }

  group('ProfileNotifier', () {
    test('starts from the profile cached by the auth bootstrap', () {
      final state = container.read(profileNotifierProvider);
      expect(state.profile?.fullName, 'Ana Rojas');
      expect(state.saving, isFalse);
      expect(state.error, isNull);
    });

    test('refresh() re-syncs with the shared cache', () {
      container
          .read(riderProfileProvider.notifier)
          .state = const RiderProfile(firstName: 'Another');

      container.read(profileNotifierProvider.notifier).refresh();

      expect(
        container.read(profileNotifierProvider).profile?.firstName,
        'Another',
      );
    });

    group('updateProfile', () {
      test('always sends photo_url so an edit that ignores it is safe',
          () async {
        // `PUT /rider/me` assigns photo_url unconditionally
        // (internal/handler/rider.go:76), so omitting it would clear the
        // stored photo server-side.
        stubPut();
        stubGet();

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(lastName: 'Updated');

        expect(ok, isTrue);
        expect(sentBody, {
          'first_name': 'Ana',
          'last_name': 'Updated',
          'photo_url': 'https://cdn.example.com/ana.png',
        });
      });

      test('fills omitted name fields from the cached profile', () async {
        stubPut();
        stubGet();

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(firstName: 'Ana');

        expect(ok, isTrue);
        expect(sentBody, {
          'first_name': 'Ana',
          'last_name': 'Rojas',
          'photo_url': 'https://cdn.example.com/ana.png',
        });
      });

      test('omits phone when the field was not filled in', () async {
        // The handler ignores an empty phone (rider.go:79), so sending one
        // would claim a change that never happened.
        stubPut();
        stubGet(phone: '');

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(firstName: 'Ana', lastName: 'Rojas');

        expect(ok, isTrue);
        expect(sentBody!.containsKey('phone'), isFalse);
      });

      test('trims whitespace before sending', () async {
        stubPut();
        stubGet();

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(
              firstName: '  Ana  ',
              lastName: '  Updated  ',
              phone: '  +5065559999  ',
            );

        expect(ok, isTrue);
        expect(sentBody, {
          'first_name': 'Ana',
          'last_name': 'Updated',
          'photo_url': 'https://cdn.example.com/ana.png',
          'phone': '+5065559999',
        });
      });

      test('writes the result through to riderProfileProvider', () async {
        stubPut();
        stubGet();

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(lastName: 'Updated');

        expect(ok, isTrue);
        expect(container.read(riderProfileProvider)?.lastName, 'Updated');
        expect(
          container.read(riderProfileProvider)?.photoUrl,
          'https://cdn.example.com/ana.png',
        );
      });

      test('re-reads GET /rider/me so the saved phone is authoritative',
          () async {
        // `PUT /rider/me` answers `{rider}` only, so the `users` row — and
        // with it the phone — is not confirmed by the save response.
        stubPut();
        stubGet(phone: '+5065559999');

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(lastName: 'Updated', phone: '+5065559999');

        expect(ok, isTrue);
        verify(() => mockDio.get(ApiEndpoints.riderMe)).called(1);
        expect(container.read(authProvider).user?.phone, '+5065559999');
      });

      test('keeps the PUT result when the re-read fails', () async {
        stubPut();
        when(() => mockDio.get(ApiEndpoints.riderMe))
            .thenThrow(NotFoundException('rider not found'));

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(lastName: 'Updated');

        expect(ok, isTrue);
        expect(container.read(riderProfileProvider)?.lastName, 'Updated');
        expect(container.read(profileNotifierProvider).error, isNull);
      });

      test('surfaces the mapped API error and keeps the old profile',
          () async {
        // The mapped ApiException is what the user should read, never Dio's
        // verbose message (see api_exceptions.dart).
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
              'status code of 422 but the status code included in the response '
              'is not a valid status code. ...',
        ));

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(firstName: 'X');

        expect(ok, isFalse);
        final state = container.read(profileNotifierProvider);
        expect(state.error, 'first_name is required');
        expect(state.error, isNot(contains('This exception')));
        expect(state.saving, isFalse);
        expect(state.profile?.fullName, 'Ana Rojas');
        expect(container.read(riderProfileProvider)?.fullName, 'Ana Rojas');
      });

      test('flags saving while the request is in flight', () async {
        final completer = Completer<Response<dynamic>>();
        when(() => mockDio.put(any(), data: any(named: 'data')))
            .thenAnswer((_) => completer.future);
        stubGet();

        final future = container
            .read(profileNotifierProvider.notifier)
            .updateProfile(lastName: 'Updated');

        expect(container.read(profileNotifierProvider).saving, isTrue);
        expect(container.read(profileNotifierProvider).error, isNull);

        completer.complete(Response(
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
        ));
        await future;

        expect(container.read(profileNotifierProvider).saving, isFalse);
      });

      test('rejects a response without a rider object', () async {
        when(() => mockDio.put(any(), data: any(named: 'data')))
            .thenAnswer((_) async => Response(
                  requestOptions: RequestOptions(path: ApiEndpoints.riderMe),
                  statusCode: 200,
                  data: <String, dynamic>{'user': <String, dynamic>{}},
                ));

        final ok = await container
            .read(profileNotifierProvider.notifier)
            .updateProfile(firstName: 'Ana');

        expect(ok, isFalse);
        expect(
          container.read(profileNotifierProvider).error,
          'Unexpected server response. Please try again.',
        );
      });
    });
  });
}
