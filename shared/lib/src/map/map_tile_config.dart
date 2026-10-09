/// A pure value object describing a map tile source.
///
/// Deliberately free of any `flutter_map` import so it can be constructed and
/// asserted without the render layer; the `TileLayer` construction lives in
/// `map_tile_layer.dart`. Both apps build one of these and hand it to the shared
/// factory rather than constructing tile layers themselves.
class MapTileConfig {
  const MapTileConfig({
    required this.urlTemplate,
    required this.userAgentPackageName,
    required this.userAgent,
    this.attribution,
    this.subdomains = const <String>[],
    this.apiKey,
  });

  /// OSM-compliant default. [userAgent] is composed truthfully as
  /// `'<appName>/<appVersion> (+contact: <contact>)'`
  /// e.g. `'rider_app/1.4.0 (+contact: tiles@example.invalid)'`. Never a browser
  /// string.
  factory MapTileConfig.openStreetMap({
    required String userAgentPackageName,
    required String appName,
    required String appVersion,
    String urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    String contact = MapTileConfig.defaultContact,
    String? apiKey,
  }) {
    return MapTileConfig(
      urlTemplate: urlTemplate,
      userAgentPackageName: userAgentPackageName,
      userAgent: '$appName/$appVersion (+contact: $contact)',
      attribution: '© OpenStreetMap contributors',
      apiKey: apiKey,
    );
  }

  final String urlTemplate;

  /// The real reverse-DNS application id, e.g. `com.example.rider_app`.
  final String userAgentPackageName;

  /// `'<appName>/<appVersion> (+contact: <email>)'` — truthful, never a browser
  /// string.
  final String userAgent;

  /// OSM/provider attribution text; null when a config carries none.
  final String? attribution;

  final List<String> subdomains;

  /// Null now; the seam for a deferred hosted-provider plan.
  final String? apiKey;

  /// PLACEHOLDER — a real ops contact MUST replace this before release. The
  /// `.invalid` TLD guarantees a shipped placeholder can never route mail and
  /// makes the non-compliance obvious; see the `[map]_android_tile_access.md`
  /// Pre-release checklist.
  static const String defaultContact = 'tiles@example.invalid';

  Map<String, String> get headers => {'User-Agent': userAgent};
}
