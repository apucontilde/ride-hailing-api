import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:dio/dio.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/features/home/providers/availability_notifier.dart';
import 'package:driver_app/features/driver/model/driver_profile.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late ProviderContainer container;
  late AvailabilityNotifier notifier;

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        availabilityProvider.overrideWith((ref) => AvailabilityNotifier(ref)),
      ],
    );
    addTearDown(container.dispose);
    notifier = container.read(availabilityProvider.notifier);
  });

  group('AvailabilityNotifier', () {
    test('initial state is offline', () {
      expect(notifier.online, isFalse);
      expect(notifier.inFlight, isFalse);
      expect(notifier.error, isNull);
    });

    test('toggle() flips online and calls PUT /driver/me/status', () async {
      when(() => mockDio.put(
        ApiEndpoints.driverMeStatus,
        data: any(named: 'data'),
      )).thenAnswer((_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMeStatus),
        statusCode: 200,
        data: {
          'driver': {
            'status': 'online',
          },
        },
      ));

      await notifier.toggle();

      expect(notifier.online, isTrue);
      expect(notifier.inFlight, isFalse);
      expect(notifier.error, isNull);
    });

    test('toggle() reverts on failure and surfaces error', () async {
      when(() => mockDio.put(
        ApiEndpoints.driverMeStatus,
        data: any(named: 'data'),
      )).thenThrow(DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMeStatus),
      ));

      await notifier.toggle();

      expect(notifier.online, isFalse);
      expect(notifier.inFlight, isFalse);
      expect(notifier.error, isNotNull);
    });

    test('double-tap is ignored while in flight', () async {
      when(() => mockDio.put(
        ApiEndpoints.driverMeStatus,
        data: any(named: 'data'),
      )).thenAnswer((_) async {
        await Future.delayed(const Duration(milliseconds: 100));
        return Response(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMeStatus),
          statusCode: 200,
          data: {'driver': {'status': 'online'}},
        );
      });

      final first = notifier.toggle();
      final second = notifier.toggle();

      await first;
      await second;

      // Only one call should result in success because second is ignored.
      expect(notifier.online, isTrue);
    });

    test('setOnline flips state without network call', () {
      notifier.setOnline();
      expect(notifier.online, isTrue);
    });

    test('setOffline flips state without network call', () {
      notifier.setOnline();
      notifier.setOffline();
      expect(notifier.online, isFalse);
    });

    test('syncFromProfile updates state from driver profile', () {
      notifier.syncFromProfile(DriverProfile(status: 'online'));
      expect(notifier.online, isTrue);
      notifier.syncFromProfile(DriverProfile(status: 'offline'));
      expect(notifier.online, isFalse);
    });

    test('onOnlineChanged tracks online/offline transitions for the heartbeat',
        () {
      // The driver app wires this to `DriverWebSocketService.setOnline`, so the
      // keep-alive must follow the switch (online pings, offline stops).
      final seen = <bool>[];
      notifier.onOnlineChanged = seen.add;

      notifier.setOnline();
      notifier.setOffline();
      notifier.syncFromProfile(DriverProfile(status: 'online'));
      notifier.syncFromProfile(null);

      expect(seen, [true, false, true, false]);
    });

    test('toggle() writes the new status into driverProfileProvider', () async {
      // Regression: the status flip used to update only `availabilityProvider`,
      // leaving the shared profile cache at its login-time value. The home
      // screen gates the offer sheet on that cache's `isOnline`, so every
      // offer delivered over the websocket was dropped and then expired —
      // "the driver never receives an offer". Covered end-to-end by
      // e2e/specs/ride-offer.spec.ts.
      container.read(driverProfileProvider.notifier).state =
          DriverProfile(status: 'offline');
      when(() => mockDio.put(
        ApiEndpoints.driverMeStatus,
        data: any(named: 'data'),
      )).thenAnswer((_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMeStatus),
        statusCode: 200,
        data: {'driver': {'status': 'online'}},
      ));

      await notifier.toggle();

      expect(notifier.online, isTrue);
      expect(
        container.read(driverProfileProvider)?.status,
        'online',
        reason: 'the shared profile cache must follow the status toggle',
      );
    });

    test('toggle() off updates the profile cache too', () async {
      container.read(driverProfileProvider.notifier).state =
          DriverProfile(status: 'online');
      notifier.syncFromProfile(DriverProfile(status: 'online'));
      when(() => mockDio.put(
        ApiEndpoints.driverMeStatus,
        data: any(named: 'data'),
      )).thenAnswer((_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMeStatus),
        statusCode: 200,
        data: {'driver': {'status': 'offline'}},
      ));

      await notifier.toggle();

      expect(notifier.online, isFalse);
      expect(container.read(driverProfileProvider)?.status, 'offline');
    });
  });
}
