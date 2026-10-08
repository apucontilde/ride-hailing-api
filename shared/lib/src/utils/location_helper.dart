import 'package:geolocator/geolocator.dart';

class LocationHelper {
  static Future<({bool granted, bool deniedPermanently})> requestPermissionDetailed() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      return (granted: false, deniedPermanently: false);
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    final granted = permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
    final deniedPermanently = permission == LocationPermission.deniedForever;
    return (granted: granted, deniedPermanently: deniedPermanently);
  }

  static Future<bool> requestPermission() async {
    final result = await requestPermissionDetailed();
    return result.granted;
  }

  static Future<Position?> getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
    } catch (e) {
      return null;
    }
  }

  /// Whether the platform location service (GPS) is switched on. Kept on the
  /// helper so app code never has to import `geolocator` directly.
  static Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  /// Opens the OS app-permission settings (for a permanently denied permission).
  static Future<bool> openAppSettings() => Geolocator.openAppSettings();

  /// Opens the OS location-service settings (for services-off).
  static Future<bool> openLocationSettings() =>
      Geolocator.openLocationSettings();

  static Stream<Position> getPositionStream() {
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    );
  }

  static double calculateDistance(
      double lat1, double lng1, double lat2, double lng2) {
    return Geolocator.distanceBetween(lat1, lng1, lat2, lng2);
  }

  static String formatDistance(double meters) {
    if (meters >= 1000) {
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    return '${meters.toStringAsFixed(0)} m';
  }

  static int estimateEtaSeconds(double distanceMeters) {
    const avgSpeedMps = 8.33;
    return (distanceMeters / avgSpeedMps).round();
  }
}