/// Minimal async key/value store backing [AuthStorage].
///
/// The concrete backend is selected at compile time in `auth_storage.dart` via
/// a conditional import: native `flutter_secure_storage` or, on web,
/// `window.localStorage`. Kept separate so the web implementation (which imports
/// `package:web` / `dart:js_interop`) never enters a native build.
abstract class AuthKeyValueStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}
