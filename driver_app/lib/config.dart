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

  /// Map tile source, read at build time (`--dart-define`/CI), never committed.
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  /// Hosted-provider API key seam. Unused on the OSM path; read at build time
  /// so it never lands in source.
  static const String mapTileApiKey = String.fromEnvironment('MAP_TILE_API_KEY');

  /// App version shown in Settings and composed into the map tile `User-Agent`.
  /// Supplied at build time (`--dart-define`/CI) so the UA tracks the shipped
  /// build; defaults to `'1.0.0'` for local runs.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
}
