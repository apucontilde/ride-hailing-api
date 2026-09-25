class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// Feature gate for vehicle & documents. The backend endpoints
  /// `GET/PUT /driver/me/vehicle` and `GET/POST /driver/me/documents` are
  /// STUBs, so the app must not build a saving surface on them. When `false`
  /// the vehicle & documents screen shows a "coming soon" empty state. Flip to
  /// `true` only once the backend ships the real endpoints.
  static const bool vehicleFeatureEnabled = false;

  /// App version shown in Settings. Kept as a const to avoid a hard dependency
  /// on `package_info_plus` for a single read-only string.
  static const String appVersion = '1.0.0';
}
