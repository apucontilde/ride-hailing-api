class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// App version shown in Settings. Kept as a const to avoid a hard dependency
  /// on `package_info_plus` for a single read-only string.
  static const String appVersion = '1.0.0';
}
