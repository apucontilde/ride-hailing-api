import 'package:web/web.dart' as web;

import 'auth_key_value_store.dart';

/// Web backend: `window.localStorage`, which survives a page reload.
///
/// Chosen over `flutter_secure_storage`'s web implementation (WebCrypto, secure
/// context, not XSS-proof) for reload reliability. The signature accepts and
/// ignores the optional `FlutterSecureStorage` so the conditional import in
/// `auth_storage.dart` type-checks against both backends.
class WebLocalStorageKeyValueStore implements AuthKeyValueStore {
  final web.Storage _storage;

  WebLocalStorageKeyValueStore([web.Storage? storage])
      : _storage = storage ?? web.window.localStorage;

  @override
  Future<String?> read(String key) async => _storage.getItem(key);

  @override
  Future<void> write(String key, String value) async =>
      _storage.setItem(key, value);

  @override
  Future<void> delete(String key) async => _storage.removeItem(key);
}

/// Selected by the conditional import in `auth_storage.dart` for web builds.
///
/// UNVERIFIABLE in the Dart VM suite: exercising real `window.localStorage`
/// needs `flutter test --platform chrome` (or a manual page reload). The VM
/// suite covers the interface with a fake instead.
AuthKeyValueStore createAuthKeyValueStore([Object? ignored]) =>
    WebLocalStorageKeyValueStore();
