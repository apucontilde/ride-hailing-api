import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';

/// One page of `GET /driver/rides/history` plus the pagination metadata the
/// server echoes back (`internal/handler/ride.go:151-189`).
///
/// Pagination is **1-based `page` + `per_page`**, not `limit`/`offset`: the
/// handler clamps `page >= 1` and `per_page` to 1..50 and silently rewrites
/// anything out of range, so a bad value comes back as a *valid-looking* page
/// rather than an error. Rides are ordered `created_at DESC` and include the
/// fare columns (`SELECT *`), which is what the client-side earnings sum needs.
class RideHistoryPage {
  final List<Ride> rides;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  const RideHistoryPage({
    required this.rides,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });
}

/// A rating the driver submitted (or received) as returned by
/// `GET /driver/ratings` / `GET /rider/ratings`.
class DriverRating {
  final String id;
  final String rideId;
  final String raterRole;
  final int score;
  final String? comment;
  final DateTime createdAt;

  const DriverRating({
    required this.id,
    required this.rideId,
    required this.raterRole,
    required this.score,
    required this.comment,
    required this.createdAt,
  });

  factory DriverRating.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final rideId = json['ride_id'] as String? ?? json['rideId'] as String? ?? '';
    final raterRole = json['rater_role'] as String? ?? json['raterRole'] as String? ?? 'rider';
    final score = (json['score'] as num?)?.toInt() ?? 0;
    final comment = json['comment'] as String?;
    final createdAtStr = json['created_at'] as String? ?? json['createdAt'] as String?;
    return DriverRating(
      id: id,
      rideId: rideId,
      raterRole: raterRole,
      score: score,
      comment: comment,
      createdAt: createdAtStr != null ? DateTime.parse(createdAtStr) : DateTime.now(),
    );
  }
}

/// One page of `GET /driver/ratings`.
class DriverRatingPage {
  final List<DriverRating> ratings;
  final int total;
  final int page;
  final int perPage;
  final int totalPages;

  const DriverRatingPage({
    required this.ratings,
    required this.total,
    required this.page,
    required this.perPage,
    required this.totalPages,
  });
}

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

  /// One page of the driver's past rides.
  Future<RideHistoryPage> history({int page = 1, int perPage = 20}) async {
    final response = await apiClient.dio.get(
      ApiEndpoints.driverRidesHistory,
      queryParameters: {'page': page, 'per_page': perPage},
    );
    final data = response.data as Map<String, dynamic>;
    final rides = (data['rides'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((json) => Ride.fromJson(json))
        .toList();
    return RideHistoryPage(
      rides: rides,
      total: (data['total'] as num?)?.toInt() ?? rides.length,
      page: (data['page'] as num?)?.toInt() ?? page,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 1,
    );
  }

  /// Rate the rider on a ride.
  ///
  /// The wire field is **`score`**, not `rating` (`rateRideRequest` in
  /// `internal/handler/ride.go:42-45`); sending `rating` binds to zero and the
  /// server answers 400. The service only range-checks the score
  /// (`internal/service/ride.go:192-206`) — it never verifies that the ride is
  /// `completed`, nor that the caller is the assigned driver — so the caller
  /// owns both rules.
  Future<void> rateRide({
    required String rideId,
    required int score,
    String? comment,
  }) async {
    if (score < 1 || score > 5) {
      throw ArgumentError.value(score, 'score', 'must be between 1 and 5');
    }
    final text = comment?.trim();
    await apiClient.dio.post(
      ApiEndpoints.driverRideRate(rideId),
      data: {
        'score': score,
        if (text != null && text.isNotEmpty) 'comment': text,
      },
    );
  }

  /// Fetch the list of ratings the driver has submitted.
  ///
  /// Every row is one the driver submitted: the handler pins `rater_role` to
  /// the caller's role (`internal/handler/ride.go:430-435`), so the response is
  /// already the "rides I rated" set and needs no client-side filter.
  ///
  /// When [rideId] is given, the request carries the server's `ride_id`
  /// existence filter instead of page/per_page: a known ride comes back as its
  /// 0-or-1 row, an unrated ride as a definitive empty list, and a malformed id
  /// as `422`. This is how a ride outside the bounded page walk is resolved
  /// exactly, without fetching every page.
  ///
  /// [cancelToken] lets a caller that goes away (a disposed provider) release
  /// the request — and its Dio timeout timers — instead of leaving them pending.
  Future<DriverRatingPage> fetchMyRatings({
    int page = 1,
    int perPage = 20,
    String? rideId,
    CancelToken? cancelToken,
  }) async {
    final response = await apiClient.dio.get(
      ApiEndpoints.driverRatings,
      queryParameters: rideId != null
          ? {'ride_id': rideId}
          : {'page': page, 'per_page': perPage},
      cancelToken: cancelToken,
    );
    final data = response.data as Map<String, dynamic>;
    final ratings = (data['ratings'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((json) => DriverRating.fromJson(json))
        .toList();
    return DriverRatingPage(
      ratings: ratings,
      total: (data['total'] as num?)?.toInt() ?? ratings.length,
      page: (data['page'] as num?)?.toInt() ?? page,
      perPage: (data['per_page'] as num?)?.toInt() ?? perPage,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 1,
    );
  }
}

final ridesRepositoryProvider = Provider<RidesRepository>((ref) {
  return RidesRepository(apiClient: ref.read(apiClientProvider));
});
