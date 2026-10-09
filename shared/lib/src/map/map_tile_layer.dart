import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'map_tile_config.dart';

/// The single tile construction used by both apps. The config's truthful,
/// contact-bearing `User-Agent` wins because it is already present in the
/// provider's headers (flutter_map only injects its own default with
/// `putIfAbsent`).
TileLayer buildMapTileLayer(MapTileConfig config) {
  return TileLayer(
    urlTemplate: config.urlTemplate,
    userAgentPackageName: config.userAgentPackageName,
    subdomains: config.subdomains,
    tileProvider: NetworkTileProvider(headers: config.headers),
  );
}

/// Test seam: production returns [buildMapTileLayer]; tests override the family
/// with a provider returning `null` so no widget test hits the network.
final mapTileLayerProvider =
    Provider.family<TileLayer?, MapTileConfig>((ref, config) => buildMapTileLayer(config));
