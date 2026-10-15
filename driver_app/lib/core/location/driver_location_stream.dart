import 'package:flutter/foundation.dart';
// `geolocator` re-exports AndroidSettings / ForegroundNotificationConfig, so the
// Android-only plugin is not imported directly (and needs no separate
// dependency). shared/ still owns only the platform-agnostic stream.
import 'package:geolocator/geolocator.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

/// The persistent-notification copy shown while the driver is online.
const String kForegroundTrackingTitle = "You're online";
const String kForegroundTrackingText = 'Sharing your location with dispatch';
const String kForegroundTrackingChannelName = 'Driver location';

/// Whether the Android foreground-service stream should be used.
///
/// Kept as a pure, testable predicate so the platform decision does not require
/// a live platform channel. The service is only ever used on Android, never on
/// web, and only while the driver is meant to be dispatchable.
@visibleForTesting
bool shouldUseForegroundService({
  required bool foregroundService,
  required bool isAndroid,
  required bool isWeb,
}) =>
    foregroundService && isAndroid && !isWeb;

/// Builds the driver's position stream.
///
/// When [foregroundService] is true on Android the stream is configured with a
/// [ForegroundNotificationConfig], so the `geolocator` plugin runs an Android
/// foreground service with an ongoing notification that keeps GPS fixes flowing
/// while the app is backgrounded or the screen is locked (driver bug #18 — an
/// online driver otherwise ages out of dispatch's 30 s window and is silently
/// skipped).
///
/// On every other platform, and while [foregroundService] is false, the shared
/// foreground-only stream is used, so an offline driver is never tracked
/// (privacy invariant: the service must not run when offline).
///
/// Caveat (verified in `geolocator_android` 4.6.2): this notification ties the
/// service to the activity. It raises the priority of the process and keeps
/// fixes flowing across ordinary backgrounding/lock, but it does not survive the
/// activity being killed by the OS. A durable background-isolate package is the
/// documented fallback if OEM killing is observed (see the plan).
Stream<Position> driverPositionStream({bool foregroundService = false}) {
  final useForeground = shouldUseForegroundService(
    foregroundService: foregroundService,
    isAndroid: defaultTargetPlatform == TargetPlatform.android,
    isWeb: kIsWeb,
  );
  if (!useForeground) {
    return LocationHelper.getPositionStream();
  }
  return Geolocator.getPositionStream(
    locationSettings: AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
      intervalDuration: const Duration(seconds: 5),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: kForegroundTrackingTitle,
        notificationText: kForegroundTrackingText,
        notificationChannelName: kForegroundTrackingChannelName,
        setOngoing: true,
        // Wake/wifi locks cost battery and are deliberately off; revisit only
        // with measurements (plan decision #5).
        enableWakeLock: false,
        enableWifiLock: false,
      ),
    ),
  );
}
