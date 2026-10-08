import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/utils/location_helper.dart';

/// Why a device fix is (un)available, collapsed into one value so Home can
/// explain the state and offer the right recovery instead of a bare snackbar.
enum LocationAvailability {
  granted,
  denied,
  deniedPermanently,
  servicesDisabled,
  unavailable,
}

/// The injectable device-location seam. The default delegates to
/// [LocationHelper]; widget tests override [locationServiceProvider] with a fake
/// so Home never touches the platform location channel.
class LocationService {
  LocationService({
    Future<bool> Function()? isServiceEnabled,
    Future<({bool granted, bool deniedPermanently})> Function()?
        requestPermissionDetailed,
    Future<Position?> Function()? getCurrentPosition,
    Future<bool> Function()? openAppSettings,
    Future<bool> Function()? openLocationSettings,
  })  : _isServiceEnabled =
            isServiceEnabled ?? LocationHelper.isLocationServiceEnabled,
        _requestPermissionDetailed = requestPermissionDetailed ??
            LocationHelper.requestPermissionDetailed,
        _getCurrentPosition =
            getCurrentPosition ?? LocationHelper.getCurrentPosition,
        _openAppSettings = openAppSettings ?? LocationHelper.openAppSettings,
        _openLocationSettings =
            openLocationSettings ?? LocationHelper.openLocationSettings;

  final Future<bool> Function() _isServiceEnabled;
  final Future<({bool granted, bool deniedPermanently})> Function()
      _requestPermissionDetailed;
  final Future<Position?> Function() _getCurrentPosition;
  final Future<bool> Function() _openAppSettings;
  final Future<bool> Function() _openLocationSettings;

  /// Maps the permission/service state to a single [LocationAvailability].
  ///
  /// Permission is resolved first so a permanently-denied rider is not
  /// mislabeled as services-off; the service switch then separates services-off
  /// from a plain denial. A platform failure (e.g. no geolocator plugin, as in a
  /// widget test) degrades to [LocationAvailability.unavailable] rather than
  /// throwing into the widget tree.
  Future<LocationAvailability> requestAvailability() async {
    try {
      final permission = await _requestPermissionDetailed();
      if (permission.granted) return LocationAvailability.granted;
      if (permission.deniedPermanently) {
        return LocationAvailability.deniedPermanently;
      }
      final enabled = await _isServiceEnabled();
      if (!enabled) return LocationAvailability.servicesDisabled;
      return LocationAvailability.denied;
    } catch (_) {
      return LocationAvailability.unavailable;
    }
  }

  Future<Position?> getCurrentPosition() => _getCurrentPosition();

  Future<bool> openAppSettings() => _openAppSettings();

  Future<bool> openLocationSettings() => _openLocationSettings();
}

final locationServiceProvider =
    Provider<LocationService>((ref) => LocationService());
