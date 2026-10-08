import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:rider_app/features/home/data/location_service.dart';

void main() {
  group('LocationService.requestAvailability', () {
    test('a granted permission maps to granted', () async {
      final service = LocationService(
        requestPermissionDetailed: () async =>
            (granted: true, deniedPermanently: false),
        isServiceEnabled: () async => true,
      );

      expect(
        await service.requestAvailability(),
        LocationAvailability.granted,
      );
    });

    test('a permanently denied permission maps to deniedPermanently',
        () async {
      var serviceChecked = false;
      final service = LocationService(
        requestPermissionDetailed: () async =>
            (granted: false, deniedPermanently: true),
        isServiceEnabled: () async {
          serviceChecked = true;
          return true;
        },
      );

      expect(
        await service.requestAvailability(),
        LocationAvailability.deniedPermanently,
      );
      // The service switch is only consulted to separate services-off from a
      // plain denial; a permanent denial short-circuits it.
      expect(serviceChecked, isFalse);
    });

    test('services off maps to servicesDisabled', () async {
      final service = LocationService(
        requestPermissionDetailed: () async =>
            (granted: false, deniedPermanently: false),
        isServiceEnabled: () async => false,
      );

      expect(
        await service.requestAvailability(),
        LocationAvailability.servicesDisabled,
      );
    });

    test('a plain denial maps to denied', () async {
      final service = LocationService(
        requestPermissionDetailed: () async =>
            (granted: false, deniedPermanently: false),
        isServiceEnabled: () async => true,
      );

      expect(await service.requestAvailability(), LocationAvailability.denied);
    });

    test('a platform failure degrades to unavailable instead of throwing',
        () async {
      final service = LocationService(
        requestPermissionDetailed: () async => throw Exception('no plugin'),
      );

      expect(
        await service.requestAvailability(),
        LocationAvailability.unavailable,
      );
    });
  });

  test('delegates position and settings opens to the injected callbacks',
      () async {
    var appSettingsOpened = false;
    var locationSettingsOpened = false;
    final service = LocationService(
      getCurrentPosition: () async => Position(
        longitude: -84.09,
        latitude: 9.93,
        timestamp: DateTime.utc(2026),
        accuracy: 1,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0.0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      ),
      openAppSettings: () async {
        appSettingsOpened = true;
        return true;
      },
      openLocationSettings: () async {
        locationSettingsOpened = true;
        return true;
      },
    );

    expect((await service.getCurrentPosition())!.latitude, 9.93);
    expect(await service.openAppSettings(), isTrue);
    expect(await service.openLocationSettings(), isTrue);
    expect(appSettingsOpened, isTrue);
    expect(locationSettingsOpened, isTrue);
  });
}
