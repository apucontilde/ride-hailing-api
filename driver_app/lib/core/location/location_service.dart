import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import 'package:geolocator/geolocator.dart';
import '../auth/auth_provider.dart';
import '../api/endpoints.dart';
import '../../features/home/providers/availability_notifier.dart';

/// Permission state for the location service.
class AppPermissionState {
  final bool granted;
  final bool deniedPermanently;

  const AppPermissionState({
    this.granted = false,
    this.deniedPermanently = false,
  });

  AppPermissionState copyWith({
    bool? granted,
    bool? deniedPermanently,
  }) {
    return AppPermissionState(
      granted: granted ?? this.granted,
      deniedPermanently: deniedPermanently ?? this.deniedPermanently,
    );
  }
}

final appPermissionProvider =
    StateProvider<AppPermissionState>((ref) => const AppPermissionState());

/// An immutable lat/lng snapshot that compares by value, so widgets only
/// rebuild when the driver actually moved.
class GeoPoint {
  final double lat;
  final double lng;

  const GeoPoint(this.lat, this.lng);

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lng == lng;

  @override
  int get hashCode => Object.hash(lat, lng);

  @override
  String toString() => 'GeoPoint($lat, $lng)';
}

/// The driver's latest GPS fix, published by [LocationService] on every stream
/// event (before the online/throttle gates, so the trip map keeps tracking the
/// car even while the server pushes are throttled). `null` until the first fix.
final lastPositionProvider = StateProvider<GeoPoint?>((ref) => null);

/// Throttled GPS ping service. Only pushes when the driver is [online];
/// buffers failed points and flushes as a batch on recovery.
class LocationService {
  final ApiClient apiClient;
  final AvailabilityNotifier availabilityNotifier;
  final Stream<Position> Function() positionStreamProvider;
  final Duration throttle;

  /// Called with the detailed permission result when
  /// [requestPermission] resolves. Wired to
  /// [appPermissionProvider] so the denial banner can fire.
  final void Function({bool granted, bool deniedPermanently})? onPermission;

  /// Called with every fix, before any online/throttle gate. Wired to
  /// [lastPositionProvider] so the trip map and route fetch have an origin.
  final void Function(Position position)? onPosition;

  StreamSubscription<Position>? _subscription;
  DateTime? _lastPushTime;
  Position? _lastPosition;
  final List<Map<String, dynamic>> _buffer = [];
  static const int _maxBuffer = 60;

  LocationService({
    required this.apiClient,
    required this.availabilityNotifier,
    Stream<Position> Function()? positionStreamProvider,
    this.throttle = const Duration(seconds: 5),
    this.onPermission,
    this.onPosition,
  }) : positionStreamProvider =
            positionStreamProvider ?? LocationHelper.getPositionStream;

  bool get active => _subscription != null;

  void start() {
    if (_subscription != null) return;
    _subscription = positionStreamProvider().listen(
      (Position position) => _onPosition(position),
      onError: (e) {
        // Silently ignore stream errors.
      },
      cancelOnError: false,
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
  }

  Future<bool> requestPermission() async {
    final result = await LocationHelper.requestPermissionDetailed();
    onPermission?.call(
      granted: result.granted,
      deniedPermanently: result.deniedPermanently,
    );
    return result.granted;
  }

  void _onPosition(Position position) {
    // Remember the fix even when the push below is gated, so going online can
    // publish it without waiting for the next one.
    _lastPosition = position;

    // Publish the fix first: the trip map / route refetch need the driver's
    // real position even when the server push below is gated or throttled.
    onPosition?.call(position);

    // Only push when online.
    if (!availabilityNotifier.online) return;

    _throttledPush(position);
  }

  /// Pushes [position] unless the throttle window is still open.
  ///
  /// Returns whether the push actually went out.
  bool _throttledPush(Position position) {
    final now = DateTime.now();
    if (_lastPushTime != null &&
        now.difference(_lastPushTime!) < throttle) {
      return false;
    }
    _lastPushTime = now;

    final point = {
      'lat': position.latitude,
      'lng': position.longitude,
      'heading': position.heading,
      'speed': position.speed,
    };

    _pushPoint(point);
    return true;
  }

  /// Publishes the most recent fix immediately, ignoring the throttle.
  ///
  /// Called when the driver goes online. Without this the driver is invisible
  /// to dispatch: `_onPosition` discards fixes while offline, and geolocator
  /// only re-emits on movement (or on its own cache interval), so a driver who
  /// went online while stationary could hold *no* `driver_positions` row at
  /// all — and dispatch only ever considers a driver whose last position is
  /// younger than 30 s. The result is a driver who is online, watching the app,
  /// and never offered a ride, with nothing on screen to explain why.
  ///
  /// No-op when no fix has arrived yet or the service is stopped; the next
  /// stream event will carry it.
  void publishLastPosition({bool force = true}) {
    final position = _lastPosition;
    if (position == null) return;
    if (!availabilityNotifier.online) return;
    if (force) {
      _lastPushTime = null;
    }
    _throttledPush(position);
  }

  Future<void> _pushPoint(Map<String, dynamic> point) async {
    try {
      await apiClient.dio.put(
        ApiEndpoints.driverLocation,
        data: point,
      );
      // Flush any buffered points after a successful single push.
      if (_buffer.isNotEmpty) {
        final batch = List<Map<String, dynamic>>.from(_buffer);
        _buffer.clear();
        await _flushBatch(batch);
      }
    } catch (e) {
      // Buffer point (bounded to 60).
      _buffer.add(point);
      if (_buffer.length > _maxBuffer) {
        _buffer.removeAt(0);
      }
      // Try batch flush when multiple points buffered.
      if (_buffer.length > 1) {
        _flushBatch(List<Map<String, dynamic>>.from(_buffer));
      }
    }
  }

  Future<void> _flushBatch(List<Map<String, dynamic>> batch) async {
    try {
      await apiClient.dio.put(
        ApiEndpoints.driverLocationBatch,
        data: {'points': batch},
      );
      if (_buffer.isNotEmpty && batch.isNotEmpty) {
        final count = batch.length > _buffer.length ? _buffer.length : batch.length;
        for (int i = 0; i < count; i++) {
          _buffer.removeAt(0);
        }
      }
    } catch (e) {
      // Batch flush failed; points remain buffered.
    }
  }
}

final locationServiceProvider = Provider<LocationService>((ref) {
  return LocationService(
    apiClient: ref.read(apiClientProvider),
    availabilityNotifier: ref.read(availabilityProvider.notifier),
    onPermission: ({bool granted = false, bool deniedPermanently = false}) {
      ref.read(appPermissionProvider.notifier).state = AppPermissionState(
        granted: granted,
        deniedPermanently: deniedPermanently,
      );
    },
    onPosition: (position) {
      ref.read(lastPositionProvider.notifier).state =
          GeoPoint(position.latitude, position.longitude);
    },
  );
});
