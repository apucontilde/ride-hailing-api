import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  group('buildMapTileLayer', () {
    test('maps the config fields onto the TileLayer', () {
      const config = MapTileConfig(
        urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.png',
        userAgentPackageName: 'com.example.rider_app',
        userAgent: 'rider_app/2.0.0 (+contact: ops@example.com)',
        subdomains: ['a', 'b'],
      );

      final layer = buildMapTileLayer(config);

      expect(layer.urlTemplate, config.urlTemplate);
      expect(layer.subdomains, config.subdomains);
      expect(layer.tileProvider.headers, {'User-Agent': config.userAgent});
    });

    test('sends the truthful UA and never a hardcoded browser UA', () {
      final config = MapTileConfig.openStreetMap(
        userAgentPackageName: 'com.example.rider_app',
        appName: 'rider_app',
        appVersion: '1.4.0',
        contact: 'ops@example.com',
      );

      final layer = buildMapTileLayer(config);
      final userAgent = layer.tileProvider.headers['User-Agent'];

      expect(userAgent, 'rider_app/1.4.0 (+contact: ops@example.com)');
      expect(userAgent, isNot(contains('Mozilla')));
      expect(userAgent, isNot(contains('Chrome')));
    });
  });
}
