import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_key_value_store.dart';

/// Native backend: wraps [FlutterSecureStorage] (Keychain / Keystore).
class SecureStorageKeyValueStore implements AuthKeyValueStore {
  final FlutterSecureStorage _storage;

  SecureStorageKeyValueStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Selected by the conditional import in `auth_storage.dart` for native builds.
///
/// [storage] stays optional so existing tests can inject a
/// `FlutterSecureStorage` mock through `AuthStorage(storage: ...)`.
AuthKeyValueStore createAuthKeyValueStore([FlutterSecureStorage? storage]) =>
    SecureStorageKeyValueStore(storage);
