import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import 'ride_status_provider.dart';

/// Whether a ride in [status] still accepts a `PUT /rides/:id/destination`.
///
/// Mirrors the API's `destinationChangeable` set exactly: `pending`, `accepted`,
/// `driver_arrived` and `in_progress` (see `internal/service/ride.go`). Any
/// terminal status is closed, and the button must not be offered there.
bool isDestinationChangeable(RideStatus status) => switch (status) {
      RideStatus.matching ||
      RideStatus.driverApproaching ||
      RideStatus.driverArrived ||
      RideStatus.onTrip =>
        true,
      _ => false,
    };

class ChangeDestinationState {
  final bool isSubmitting;
  final String? error;
  final bool succeeded;

  const ChangeDestinationState({
    this.isSubmitting = false,
    this.error,
    this.succeeded = false,
  });
}

/// The mid-trip destination change (`PUT /rides/:id/destination`).
///
/// The server mutates the ride and pushes `ride.updated` to both parties, so
/// this notifier only owns the request and the surfaceable error — it never
/// re-routes or reprices. Error text is the API's own `error.message` where the
/// envelope carries one; the status-specific fallbacks cover a body that does
/// not.
class ChangeDestinationNotifier extends StateNotifier<ChangeDestinationState> {
  ChangeDestinationNotifier(this._apiClient)
      : super(const ChangeDestinationState());

  final ApiClient _apiClient;
  bool _disposed = false;

  Future<bool> changeDestination(
    String rideId, {
    required double lat,
    required double lng,
    required String address,
  }) async {
    if (state.isSubmitting) return false;
    _write(const ChangeDestinationState(isSubmitting: true));
    try {
      await _apiClient.dio.put(
        ApiEndpoints.changeDestination(rideId),
        data: {'lat': lat, 'lng': lng, 'address': address},
      );
      _write(const ChangeDestinationState(succeeded: true));
      return true;
    } on DioException catch (e) {
      final fallback = switch (e.response?.statusCode) {
        409 => 'Destination can no longer be changed',
        404 => 'This ride could not be found',
        _ => 'Failed to change destination',
      };
      _write(ChangeDestinationState(error: apiErrorMessage(e, fallback)));
      return false;
    } on ApiException catch (e) {
      _write(ChangeDestinationState(error: e.message));
      return false;
    } catch (e) {
      _write(ChangeDestinationState(error: e.toString()));
      return false;
    }
  }

  void reset() => _write(const ChangeDestinationState());

  void _write(ChangeDestinationState next) {
    if (_disposed) return;
    state = next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final changeDestinationProvider =
    StateNotifierProvider<ChangeDestinationNotifier, ChangeDestinationState>(
        (ref) {
  return ChangeDestinationNotifier(ref.read(apiClientProvider));
});
