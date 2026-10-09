import 'package:flutter_test/flutter_test.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

void main() {
  MapTileConfig riderConfig({
    String appVersion = '1.4.0',
    String? contact,
    String? urlTemplate,
  }) {
    return MapTileConfig.openStreetMap(
      userAgentPackageName: 'com.example.rider_app',
      appName: 'rider_app',
      appVersion: appVersion,
      contact: contact ?? MapTileConfig.defaultContact,
      urlTemplate: urlTemplate ??
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    );
  }

  group('MapTileConfig.openStreetMap', () {
    test('composes the UA in the exact truthful contact-bearing form', () {
      final config = riderConfig(contact: 'ops@example.com');
      expect(config.userAgent, 'rider_app/1.4.0 (+contact: ops@example.com)');
    });

    test('defaults the UA contact to the .invalid placeholder', () {
      final config = riderConfig();
      expect(MapTileConfig.defaultContact, 'tiles@example.invalid');
      expect(config.userAgent, 'rider_app/1.4.0 (+contact: tiles@example.invalid)');
    });

    test('never emits a browser-spoofed User-Agent', () {
      final config = riderConfig();
      expect(config.userAgent, isNot(contains('Mozilla')));
      expect(config.userAgent, isNot(contains('Chrome')));
      expect(config.userAgent, isNot(contains('AppleWebKit')));
      expect(config.userAgent, isNot(contains('Safari')));
    });

    test('headers is exactly the User-Agent map', () {
      final config = riderConfig(contact: 'ops@example.com');
      expect(config.headers, {'User-Agent': config.userAgent});
    });

    test('populates the OSM default url, attribution and empty seams', () {
      final config = riderConfig();
      expect(
        config.urlTemplate,
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      );
      expect(config.attribution, '© OpenStreetMap contributors');
      expect(config.userAgentPackageName, 'com.example.rider_app');
      expect(config.apiKey, isNull);
      expect(config.subdomains, isEmpty);
    });

    test('keeps a caller-supplied url template', () {
      final config = riderConfig(
        urlTemplate: 'https://tiles.example.com/{z}/{x}/{y}.png',
      );
      expect(config.urlTemplate, 'https://tiles.example.com/{z}/{x}/{y}.png');
    });
  });
}
