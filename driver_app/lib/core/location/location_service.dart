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

/// Throttled GPS ping service. Only pushes when the driver is [online];
/// buffers failed points and flushes as a batch on recovery.
class LocationService {
  final ApiClient apiClient;
  final AvailabilityNotifier availabilityNotifier;
  final Stream<Position> Function() positionStreamProvider;
  final Duration throttle;

  StreamSubscription<Position>? _subscription;
  DateTime? _lastPushTime;
  final List<Map<String, dynamic>> _buffer = [];
  static const int _maxBuffer = 60;

  LocationService({
    required this.apiClient,
    required this.availabilityNotifier,
    Stream<Position> Function()? positionStreamProvider,
    this.throttle = const Duration(seconds: 5),
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
    return await LocationHelper.requestPermission();
  }

  void _onPosition(Position position) {
    // Only push when online.
    if (!availabilityNotifier.online) return;

    // Throttle to ≥5 s between pings.
    final now = DateTime.now();
    if (_lastPushTime != null &&
        now.difference(_lastPushTime!) < throttle) {
      return;
    }
    _lastPushTime = now;

    final point = {
      'lat': position.latitude,
      'lng': position.longitude,
      'heading': position.heading,
      'speed': position.speed,
    };

    _pushPoint(point);
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
  );
});
