import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';

class RidesRepository {
  final ApiClient apiClient;

  RidesRepository({required this.apiClient});

  /// Fetch full ride detail for the offer dialog.
  Future<Ride> fetchRide(String id) async {
    final response = await apiClient.dio.get(
      ApiEndpoints.driverRideById(id),
    );
    final data = response.data as Map<String, dynamic>;
    final rideData = data['ride'] as Map<String, dynamic>? ?? data;
    return Ride.fromJson(rideData);
  }

  /// HTTP fallback accept when the WS is dead.
  /// Throws [OfferExpiredException] on 409 (offer lost / ride taken).
  Future<void> acceptRideHttp(String id) async {
    try {
      await apiClient.dio.post(
        ApiEndpoints.driverRideAccept(id),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        throw OfferExpiredException();
      }
      rethrow;
    }
  }

  /// The driver's active ride, or `null` when there is none. The websocket has
  /// no replay, so this is how a cold start (or a crash mid-trip) recovers the
  /// trip the driver is already on.
  Future<Ride?> currentRide() async {
    final response = await apiClient.dio.get(ApiEndpoints.driverRidesCurrent);
    final data = response.data as Map<String, dynamic>;
    final rideData = data['ride'] as Map<String, dynamic>?;
    if (rideData == null) return null;
    return Ride.fromJson(rideData);
  }
}

final ridesRepositoryProvider = Provider<RidesRepository>((ref) {
  return RidesRepository(apiClient: ref.read(apiClientProvider));
});
