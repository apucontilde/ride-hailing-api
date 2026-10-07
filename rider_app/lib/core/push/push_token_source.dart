import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The platform discriminator the API accepts for a device token
/// (`POST /api/v1/devices`, `internal/handler/platform.go` — `oneof=ios android
/// web`). A blank or unknown value is rejected with `422`, so callers must
/// never send an empty string.
enum DevicePlatform {
  ios('ios'),
  android('android'),
  web('web');

  const DevicePlatform(this.wireValue);

  /// The exact string the backend expects.
  final String wireValue;
}

/// Resolves the current platform into the `platform` field of the register
/// body. Web wins over the target platform (Flutter web reports a host
/// `TargetPlatform` too); desktop targets are not a supported backend value and
/// fall back to `android`, which keeps a rider build from ever sending a blank
/// or unknown discriminator.
DevicePlatform currentDevicePlatform() {
  if (kIsWeb) return DevicePlatform.web;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
      return DevicePlatform.ios;
    case TargetPlatform.android:
      return DevicePlatform.android;
    default:
      return DevicePlatform.android;
  }
}

/// The seam between the device-token registration logic and the push SDK.
///
/// The production binding is deliberately deferred: no Firebase/Messaging
/// credential-free plugin is installed yet, so [pushTokenSourceProvider] ships
/// a [NoopPushTokenSource]. Wiring a real FCM/APNs source later is a single
/// provider override — [DeviceTokenService] only depends on this interface.
///
/// Everything here is best-effort: [getToken] may return `null` (permission
/// denied, unsupported platform, or the SDK not yet initialized) and no token
/// must ever be logged.
abstract class PushTokenSource {
  /// Requests notification permission as needed and returns the current push
  /// token, or `null` when there is no token to register.
  Future<String?> getToken();

  /// Emits a new token whenever the SDK rotates it. Registering the new token
  /// reassigns delivery for this device.
  Stream<String> get onTokenRefresh;
}

/// Credential-free default: no push SDK, therefore no token and no refresh
/// events. Registration becomes a graceful no-op (see the plan's deferred
/// binding note) while the seam stays fully wired.
class NoopPushTokenSource implements PushTokenSource {
  const NoopPushTokenSource();

  @override
  Future<String?> getToken() async => null;

  @override
  Stream<String> get onTokenRefresh => const Stream<String>.empty();
}

/// The push SDK binding. Override in a real build (or a test) to install a
/// source that can actually mint tokens.
final pushTokenSourceProvider = Provider<PushTokenSource>(
  (ref) => const NoopPushTokenSource(),
);
