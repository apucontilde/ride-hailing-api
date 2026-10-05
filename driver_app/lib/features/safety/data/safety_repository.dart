import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';

/// The two ack-only platform calls the driver app makes.
///
/// Both backend handlers are smoke-grade — `POST /sos` records nothing beyond an
/// `active` alert in the response, and `POST /feedback` returns a message — so
/// there is no follow-up state to read back. The repository still lets the
/// [DioException] escape: the screen decides between a success and an error
/// snackbar, and a swallowed failure would leave a driver believing an SOS went
/// out when it did not.
class SafetyRepository {
  final ApiClient apiClient;

  SafetyRepository({required this.apiClient});

  Future<void> sendSos({required double lat, required double lng}) async {
    await apiClient.dio.post(
      ApiEndpoints.sos,
      data: {'lat': lat, 'lng': lng},
    );
  }

  Future<void> sendFeedback({
    required String type,
    required String message,
  }) async {
    await apiClient.dio.post(
      ApiEndpoints.feedback,
      data: {'type': type, 'message': message},
    );
  }
}

final safetyRepositoryProvider = Provider<SafetyRepository>((ref) {
  return SafetyRepository(apiClient: ref.read(apiClientProvider));
});
