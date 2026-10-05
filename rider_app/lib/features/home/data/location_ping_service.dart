import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/utils/location_helper.dart';

class LocationPingService {
  LocationPingService(
    this._apiClient, {
    Stream<Position> Function()? positionStream,
    DateTime Function()? now,
  })  : _positionStream = positionStream ?? LocationHelper.getPositionStream,
        _now = now ?? DateTime.now;

  static const Duration throttle = Duration(seconds: 5);

  final ApiClient _apiClient;
  final Stream<Position> Function() _positionStream;
  final DateTime Function() _now;

  StreamSubscription<Position>? _subscription;
  DateTime? _lastSentAt;
  bool _active = false;

  /// How many screens currently want a location stream. The flow routes use
  /// `context.go`, and go_router mounts the incoming screen before it disposes
  /// the outgoing one, so `home` is still mounted for a frame after
  /// `driver-matching`/`active-ride` calls [start]. Without the lease count,
  /// home's `dispose()` would [stop] the stream the incoming screen just
  /// started, and the rider's position would go dark for the whole trip. The
  /// stream is subscribed once and torn down when the last lease is released.
  int _leases = 0;

  bool get isActive => _active;

  /// Acquires a lease and, on the first one, subscribes to the position stream.
  /// Idempotent for the caller: repeated [start] calls are safe and do not
  /// create a second subscription.
  void start() {
    _leases++;
    if (_active) return;
    _active = true;
    try {
      _subscription = _positionStream().listen(
        _onPosition,
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      _active = false;
    }
  }

  /// Releases one lease; the subscription is cancelled only when no screen
  /// holds a lease any more. Safe to call more often than [start].
  Future<void> stop() async {
    if (_leases > 0) _leases--;
    if (_leases > 0) return;
    _active = false;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  Future<void> _onPosition(Position position) async {
    final now = _now();
    final last = _lastSentAt;
    if (last != null && now.difference(last) < throttle) return;
    _lastSentAt = now;
    try {
      await _apiClient.dio.put(
        ApiEndpoints.riderLocation,
        data: {'lat': position.latitude, 'lng': position.longitude},
      );
    } on DioException {
      // Best-effort telemetry: a dropped ping never surfaces to the rider.
    }
  }
}

final locationPingServiceProvider = Provider<LocationPingService>((ref) {
  return LocationPingService(ref.read(apiClientProvider));
});
