import 'package:flutter_test/flutter_test.dart';

import 'package:driver_app/core/location/driver_location_stream.dart';

void main() {
  group('shouldUseForegroundService', () {
    test('true only for an online Android non-web target', () {
      expect(
        shouldUseForegroundService(
          foregroundService: true,
          isAndroid: true,
          isWeb: false,
        ),
        isTrue,
      );
    });

    test('false while offline (privacy: the service must not run)', () {
      expect(
        shouldUseForegroundService(
          foregroundService: false,
          isAndroid: true,
          isWeb: false,
        ),
        isFalse,
      );
    });

    test('false on non-Android and on web', () {
      expect(
        shouldUseForegroundService(
          foregroundService: true,
          isAndroid: false,
          isWeb: false,
        ),
        isFalse,
      );
      expect(
        shouldUseForegroundService(
          foregroundService: true,
          isAndroid: true,
          isWeb: true,
        ),
        isFalse,
      );
    });
  });

  test('notification copy is stable and driver-facing', () {
    // The persistent notification must be honest about what is happening.
    expect(kForegroundTrackingTitle, "You're online");
    expect(kForegroundTrackingText, contains('location'));
    expect(kForegroundTrackingChannelName, isNotEmpty);
  });
}
