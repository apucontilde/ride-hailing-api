import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';
import '../model/driver_earnings.dart';

/// The driver earnings + withdrawal wire layer.
///
/// Built on the app's single [ApiClient] (`apiClientProvider`) — there is no
/// second HTTP client, so auth/refresh/error mapping behave exactly as every
/// other driver call. Error status codes arrive already typed by the shared
/// error interceptor: `409` → [ConflictException] (insufficient balance),
/// `422` → [ValidationException] (amount rejected), `5xx` → [ServerException].
/// Read the public message with `apiErrorMessage` — never `DioException.message`.
class PayoutRepository {
  final ApiClient apiClient;

  PayoutRepository({required this.apiClient});

  /// `GET /driver/me/earnings`. A driver with no earnings gets a zeroed
  /// summary, never a 404.
  Future<DriverEarningsSummary> fetchEarnings() async {
    final response = await apiClient.dio.get(ApiEndpoints.driverEarnings);
    final data = response.data as Map<String, dynamic>;
    final earnings = data['earnings'];
    return DriverEarningsSummary.fromJson(
      earnings is Map<String, dynamic> ? earnings : const <String, dynamic>{},
    );
  }

  /// `POST /driver/earnings/withdraw` with the replay-safe `Idempotency-Key`
  /// header. Returns the recorded debit and the updated summary the server
  /// computed. The withdrawal is a **pending ledger entry, not a bank
  /// transfer** — the caller's copy must say so.
  Future<WithdrawalResult> requestWithdrawal({
    required int amountCents,
    required String idempotencyKey,
  }) async {
    final response = await apiClient.dio.post(
      ApiEndpoints.driverEarningsWithdraw,
      data: {'amount_cents': amountCents},
      options: Options(headers: {'Idempotency-Key': idempotencyKey}),
    );
    final data = response.data as Map<String, dynamic>;
    final withdrawal = data['withdrawal'];
    final earnings = data['earnings'];
    return WithdrawalResult(
      withdrawal: DriverWithdrawal.fromJson(
        withdrawal is Map<String, dynamic> ? withdrawal : const <String, dynamic>{},
      ),
      earnings: DriverEarningsSummary.fromJson(
        earnings is Map<String, dynamic> ? earnings : const <String, dynamic>{},
      ),
    );
  }
}

final payoutRepositoryProvider = Provider<PayoutRepository>((ref) {
  return PayoutRepository(apiClient: ref.read(apiClientProvider));
});
