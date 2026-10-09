import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../../config.dart';

/// The driver's app-local tile config, built from compile-time constants and
/// handed to the shared `mapTileLayerProvider`. The app never constructs a
/// `TileLayer` itself.
final driverMapTileConfigProvider = Provider<MapTileConfig>((ref) {
  return MapTileConfig.openStreetMap(
    userAgentPackageName: 'com.example.driver_app',
    appName: 'driver_app',
    appVersion: ApiConfig.appVersion,
    urlTemplate: ApiConfig.mapTileUrl,
    contact: 'ricardoapuch@gmail.com',
    apiKey: ApiConfig.mapTileApiKey.isEmpty ? null : ApiConfig.mapTileApiKey,
  );
});
