import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import 'web_platform_probe.dart'
    if (dart.library.js_interop) 'web_platform_probe_web.dart';

/// In-memory [AuthKeyValueStore] standing in for the platform backends.
class InMemoryAuthKeyValueStore implements AuthKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

/// A backend whose every operation fails, to prove [AuthStorage] swallows it.
class ThrowingAuthKeyValueStore implements AuthKeyValueStore {
  @override
  Future<String?> read(String key) async => throw Exception('read failed');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('write failed');

  @override
  Future<void> delete(String key) async => throw Exception('delete failed');
}

void main() {
  group('AuthStorage round-trip', () {
    test('persists and clears both tokens', () async {
      final authStorage =
          AuthStorage(store: InMemoryAuthKeyValueStore());

      await authStorage.saveTokens(accessToken: 'access-1', refreshToken: 'r-1');

      expect(await authStorage.getAccessToken(), 'access-1');
      expect(await authStorage.getRefreshToken(), 'r-1');

      await authStorage.clearTokens();

      expect(await authStorage.getAccessToken(), isNull);
      expect(await authStorage.getRefreshToken(), isNull);
    });

    test('persists and clears the remembered email independently', () async {
      final authStorage =
          AuthStorage(store: InMemoryAuthKeyValueStore());

      await authStorage.saveTokens(accessToken: 'a', refreshToken: 'r');
      await authStorage.saveRememberedEmail('me@example.com');
      expect(await authStorage.getRememberedEmail(), 'me@example.com');

      await authStorage.clearTokens();
      expect(await authStorage.getRememberedEmail(), 'me@example.com');

      await authStorage.saveRememberedEmail(null);
      expect(await authStorage.getRememberedEmail(), isNull);
    });
  });

  group('AuthStorage failure swallowing', () {
    test('reads return null and writes never throw', () async {
      final authStorage = AuthStorage(store: ThrowingAuthKeyValueStore());

      expect(await authStorage.getAccessToken(), isNull);
      expect(await authStorage.getRefreshToken(), isNull);
      expect(await authStorage.getRememberedEmail(), isNull);

      await authStorage.saveAccessToken('a');
      await authStorage.saveRefreshToken('r');
      await authStorage.saveTokens(accessToken: 'a', refreshToken: 'r');
      await authStorage.saveRememberedEmail('me@example.com');
      await authStorage.saveRememberedEmail(null);
      await authStorage.clearTokens();
    });
  });

  group('AuthStorage web backend', () {
    // Browser-only: exercises the real `window.localStorage` adapter through a
    // second AuthStorage instance, emulating a page reload. Skipped in the VM
    // suite (the native build selects the flutter_secure_storage backend);
    // verified with `flutter test --platform chrome` from `shared/`.
    test('persists and clears through the real window.localStorage', () async {
      final storage = AuthStorage();
      await storage.saveTokens(accessToken: 'web-access', refreshToken: 'web-r');

      final reloaded = AuthStorage();
      expect(await reloaded.getAccessToken(), 'web-access');
      expect(await reloaded.getRefreshToken(), 'web-r');

      await storage.clearTokens();
      expect(await reloaded.getAccessToken(), isNull);
      expect(await reloaded.getRefreshToken(), isNull);
    }, skip: !isWebPlatform);
  });
}
