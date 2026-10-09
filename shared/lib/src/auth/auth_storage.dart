import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'auth_key_value_store.dart';
import 'auth_key_value_store_native.dart'
    if (dart.library.js_interop) 'auth_key_value_store_web.dart';

/// Thin wrapper over a platform [AuthKeyValueStore].
///
/// Backed by `flutter_secure_storage` on native and `window.localStorage` on web
/// (chosen at compile time via the conditional import above). Every read returns
/// `null` on failure and every write is best-effort: the in-memory token held by
/// `ApiClient` is the session of record, so a storage fault degrades to an
/// in-memory session instead of a crash or a forced re-login.
class AuthStorage {
  final AuthKeyValueStore _store;

  AuthStorage({FlutterSecureStorage? storage, AuthKeyValueStore? store})
      : _store = store ?? createAuthKeyValueStore(storage);

  static const _accessTokenKey = 'access_token';
  static const _refreshTokenKey = 'refresh_token';
  static const _rememberedEmailKey = 'remembered_email';

  Future<void> saveAccessToken(String token) async {
    await _write(_accessTokenKey, token);
  }

  Future<void> saveRefreshToken(String token) async {
    await _write(_refreshTokenKey, token);
  }

  Future<String?> getAccessToken() => _read(_accessTokenKey);

  Future<String?> getRefreshToken() => _read(_refreshTokenKey);

  Future<void> saveRememberedEmail(String? email) async {
    if (email == null) {
      await _delete(_rememberedEmailKey);
    } else {
      await _write(_rememberedEmailKey, email);
    }
  }

  Future<String?> getRememberedEmail() => _read(_rememberedEmailKey);

  Future<void> clearTokens() async {
    await _delete(_accessTokenKey);
    await _delete(_refreshTokenKey);
  }

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
  }) async {
    await saveAccessToken(accessToken);
    await saveRefreshToken(refreshToken);
  }

  Future<String?> _read(String key) async {
    try {
      return await _store.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _store.write(key, value);
    } catch (_) {
      // Best-effort: the in-memory token remains the session of record.
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _store.delete(key);
    } catch (_) {
      // Best-effort.
    }
  }
}
