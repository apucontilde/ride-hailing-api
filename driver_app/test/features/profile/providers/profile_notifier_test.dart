import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:driver_app/core/api/api_client.dart';
import 'package:driver_app/core/api/api_exceptions.dart';
import 'package:driver_app/core/api/endpoints.dart';
import 'package:driver_app/core/auth/auth_provider.dart';
import 'package:driver_app/features/driver/model/driver_profile.dart';
import 'package:driver_app/features/profile/providers/profile_notifier.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockDio extends Mock implements Dio {}

/// `ProfileNotifier` is what `profile_screen.dart` delegates its save to, and
/// what onboarding now calls after registration, so these tests pin the three
/// behaviours both depend on: a sparse `PUT` body, a response that replaces the
/// cache, and a failure that keeps the old profile and surfaces the message.
void main() {
  late MockApiClient mockApiClient;
  late MockDio mockDio;
  late ProviderContainer container;

  const seeded = DriverProfile(
    userId: 'd1',
    firstName: 'Ava',
    lastName: 'Lopez',
    status: 'online',
    onboardingStatus: 'verified',
    ratingSummary: '4.8',
  );

  setUp(() {
    mockApiClient = MockApiClient();
    mockDio = MockDio();
    when(() => mockApiClient.dio).thenReturn(mockDio);
  });

  ProviderContainer buildContainer() {
    final c = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(mockApiClient),
        driverProfileProvider.overrideWith((ref) => seeded),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Response<dynamic> driverResponse(DriverProfile driver) => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
        statusCode: 200,
        data: {
          'driver': {
            'user_id': driver.userId,
            'first_name': driver.firstName,
            'last_name': driver.lastName,
            'photo_url': driver.photoUrl,
            'status': driver.status,
            'onboarding_status': driver.onboardingStatus,
            'rating_summary': driver.ratingSummary,
          },
        },
      );

  test('sends only the fields it was given', () async {
    container = buildContainer();
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenAnswer((_) async => driverResponse(seeded));
    final notifier = container.read(profileNotifierProvider.notifier);

    final ok = await notifier.updateProfile(firstName: 'Ava');

    expect(ok, isTrue);
    final captured = verify(
      () => mockDio.put(ApiEndpoints.driverMe, data: captureAny(named: 'data')),
    ).captured;
    expect(captured.single, {'first_name': 'Ava'});
    expect(captured.single, isNot(contains('last_name')));
    expect(captured.single, isNot(contains('phone')));
  });

  test('trims provided values and drops blank ones', () async {
    container = buildContainer();
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenAnswer((_) async => driverResponse(seeded));
    final notifier = container.read(profileNotifierProvider.notifier);

    await notifier.updateProfile(
      firstName: '  Ava  ',
      lastName: '   ',
      phone: ' 555-0100 ',
    );

    final captured = verify(
      () => mockDio.put(ApiEndpoints.driverMe, data: captureAny(named: 'data')),
    ).captured;
    expect(captured.single, {'first_name': 'Ava', 'phone': '555-0100'});
  });

  test('the response replaces the cached profile', () async {
    container = buildContainer();
    const updated = DriverProfile(
      userId: 'd1',
      firstName: 'Ava',
      lastName: 'Nguyen',
      status: 'online',
      onboardingStatus: 'verified',
      ratingSummary: '4.9',
    );
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenAnswer((_) async => driverResponse(updated));
    final notifier = container.read(profileNotifierProvider.notifier);

    await notifier.updateProfile(lastName: 'Nguyen');

    expect(container.read(driverProfileProvider)?.lastName, 'Nguyen');
    expect(notifier.state.driver?.lastName, 'Nguyen');
    expect(notifier.state.driver?.ratingSummary, '4.9');
    expect(notifier.state.saving, isFalse);
    expect(notifier.state.error, isNull);
  });

  test('a failure keeps the old profile and surfaces the message', () async {
    container = buildContainer();
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenThrow(
      DioException(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
        response: Response(
          requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
          statusCode: 500,
          data: {
            'error': {'code': 'INTERNAL', 'message': 'boom'},
          },
        ),
        error: mapStatusCodeToException(500, 'boom'),
      ),
    );
    final notifier = container.read(profileNotifierProvider.notifier);

    final ok = await notifier.updateProfile(firstName: 'Zed');

    expect(ok, isFalse);
    expect(notifier.state.driver?.firstName, 'Ava');
    expect(container.read(driverProfileProvider)?.firstName, 'Ava');
    expect(notifier.state.saving, isFalse);
    expect(notifier.state.error, 'boom');
  });

  test('a malformed response surfaces an error rather than a blank profile', () async {
    container = buildContainer();
    when(() => mockDio.put(ApiEndpoints.driverMe, data: any(named: 'data')))
        .thenAnswer(
      (_) async => Response(
        requestOptions: RequestOptions(path: ApiEndpoints.driverMe),
        statusCode: 200,
        data: {'not_driver': true},
      ),
    );
    final notifier = container.read(profileNotifierProvider.notifier);

    final ok = await notifier.updateProfile(firstName: 'Zed');

    expect(ok, isFalse);
    expect(notifier.state.driver?.firstName, 'Ava');
    expect(notifier.state.error, isNotNull);
  });
}
