import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/utils/location_helper.dart';
import 'ride_status_provider.dart';

class SecurityState {
  final bool isSending;
  final bool success;
  final String? error;

  const SecurityState({
    this.isSending = false,
    this.success = false,
    this.error,
  });
}

class SecurityNotifier extends StateNotifier<SecurityState> {
  SecurityNotifier(
    this._apiClient, {
    Future<Position?> Function()? lastPosition,
    (double, double)? Function()? fallbackPosition,
  })  : _lastPosition = lastPosition ?? LocationHelper.getCurrentPosition,
        _fallbackPosition = fallbackPosition ?? (() => null),
        super(const SecurityState());

  final ApiClient _apiClient;
  final Future<Position?> Function() _lastPosition;
  final (double, double)? Function() _fallbackPosition;

  Future<void> sendSos() async {
    if (state.isSending) return;
    state = const SecurityState(isSending: true);
    final coords = await _resolvePosition();
    if (coords == null) {
      state = const SecurityState(
        error: 'Could not determine your location. '
            'Turn on location and try again.',
      );
      return;
    }
    try {
      await _apiClient.dio.post(
        ApiEndpoints.sos,
        data: {'lat': coords.$1, 'lng': coords.$2},
      );
      state = const SecurityState(success: true);
    } on DioException catch (e) {
      state = SecurityState(
        error: apiErrorMessage(e, 'Failed to send the emergency alert'),
      );
    }
  }

  Future<(double, double)?> _resolvePosition() async {
    try {
      final position = await _lastPosition();
      if (position != null) return (position.latitude, position.longitude);
    } catch (_) {
      // Fall through to the ride's pickup as a last resort.
    }
    return _fallbackPosition();
  }

  void reset() {
    state = const SecurityState();
  }
}

final securityProvider =
    StateNotifierProvider<SecurityNotifier, SecurityState>((ref) {
  return SecurityNotifier(
    ref.read(apiClientProvider),
    fallbackPosition: () {
      final data = ref.read(rideStatusProvider).rideData;
      final lat = (data?['pickup_lat'] as num?)?.toDouble();
      final lng = (data?['pickup_lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return null;
      return (lat, lng);
    },
  );
});
