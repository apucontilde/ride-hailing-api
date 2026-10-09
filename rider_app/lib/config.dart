class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8080',
  );

  /// Map tile source, read at build time (`--dart-define`/CI), never committed.
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  /// Hosted-provider API key seam. Unused on the OSM path; read at build time
  /// so it never lands in source.
  static const String mapTileApiKey = String.fromEnvironment('MAP_TILE_API_KEY');

  /// UA version component: `'<app>/<appVersion> (+contact: ...)'`. Set from the
  /// release version (build define / CI) so the UA tracks the shipped build.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
}
