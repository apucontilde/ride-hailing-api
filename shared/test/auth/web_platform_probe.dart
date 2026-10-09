/// Native counterpart of `web_platform_probe_web.dart`.
///
/// The conditional import in `auth_storage_test.dart` selects the web file only
/// for a `dart.library.js_interop` build, so the VM suite can skip the
/// browser-only persistence test instead of failing on a missing platform
/// channel.
const bool isWebPlatform = false;
