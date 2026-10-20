import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ride_hailing_shared/ride_hailing_shared.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/endpoints.dart';
import '../../trip/model/ride_stop.dart';

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
    final rideId =
        json['ride_id'] as String? ?? json['rideId'] as String? ?? '';
    final raterRole =
        json['rater_role'] as String? ??
        json['raterRole'] as String? ??
        'rider';
    final score = (json['score'] as num?)?.toInt() ?? 0;
    final comment = json['comment'] as String?;
    final createdAtStr =
        json['created_at'] as String? ?? json['createdAt'] as String?;
    return DriverRating(
      id: id,
      rideId: rideId,
      raterRole: raterRole,
      score: score,
      comment: comment,
      createdAt: createdAtStr != null
          ? DateTime.parse(createdAtStr)
          : DateTime.now(),
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

/// A `GET /navigation/route` result for the offer sheet's honest trip estimate.
/// [isEstimate] mirrors the backend's `is_estimate` (no road coverage → a
/// straight-line fallback), so the UI can label it as an estimate.
class RouteEstimate {
  final double distanceM;
  final int durationS;
  final bool isEstimate;

  const RouteEstimate({
    required this.distanceM,
    required this.durationS,
    required this.isEstimate,
  });
}

/// A ride plus the sibling `stops` itinerary. The API returns `stops` as an
/// array alongside `ride` (`internal/handler/ride.go`), ordered by `sequence`
/// and excluding the pickup; its last row is the destination. The plain
/// `fetchRide`/`currentRide` read methods keep returning only the [Ride].
class RideItinerary {
  final Ride ride;
  final List<RideStop> stops;

  const RideItinerary({required this.ride, required this.stops});
}

class RidesRepository {
  final ApiClient apiClient;

  RidesRepository({required this.apiClient});

  /// Fetch full ride detail for the offer dialog.
  Future<Ride> fetchRide(String id) async {
    final response = await apiClient.dio.get(ApiEndpoints.driverRideById(id));
    final data = response.data as Map<String, dynamic>;
    final rideData = data['ride'] as Map<String, dynamic>? ?? data;
    return Ride.fromJson(rideData);
  }

  /// Server-confirmed accept (`POST /driver/rides/:id/accept`). Resolves only
  /// after the assignment committed (200).
  ///
  /// 404 (no live offer for this driver) and 409 (ride no longer pending) both
  /// mean the offer is gone for the driver and throw [OfferExpiredException],
  /// preserving the API message. 422 is a programming error and, like 5xx /
  /// network failures, is rethrown so the sheet stays usable and retryable.
  Future<void> acceptRideHttp(String id) async {
    try {
      await apiClient.dio.post(ApiEndpoints.driverRideAccept(id));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404 || status == 409) {
        throw OfferExpiredException(
          apiErrorMessage(e, 'Offer expired or ride taken'),
        );
      }
      rethrow;
    }
  }

  /// Full ride detail plus the sibling `stops` itinerary for one ride.
  ///
  /// `fetchRide` stays ride-only for the offer sheet; this is the trip layer's
  /// itinerary source. Degrades to `[]` when the `stops` key is absent.
  Future<RideItinerary> fetchRideItinerary(String id) async {
    final response = await apiClient.dio.get(ApiEndpoints.driverRideById(id));
    final data = response.data as Map<String, dynamic>;
    final rideData = data['ride'] as Map<String, dynamic>? ?? data;
    return RideItinerary(
      ride: Ride.fromJson(rideData),
      stops: _parseStops(data['stops']),
    );
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

  /// Like [currentRide], but also parses the sibling `stops` itinerary.
  Future<RideItinerary?> currentRideItinerary() async {
    final response = await apiClient.dio.get(ApiEndpoints.driverRidesCurrent);
    final data = response.data as Map<String, dynamic>;
    final rideData = data['ride'] as Map<String, dynamic>?;
    if (rideData == null) return null;
    return RideItinerary(
      ride: Ride.fromJson(rideData),
      stops: _parseStops(data['stops']),
    );
  }

  /// The road route from `(fromLat, fromLng)` to `(toLat, toLng)` as a distance
  /// and duration estimate, used by the offer sheet. The endpoint is
  /// Bearer-authenticated for drivers; `is_estimate` is preserved so the caller
  /// never presents a fallback as a road route.
  Future<RouteEstimate> routeEstimate({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    final response = await apiClient.dio.get(
      ApiEndpoints.navigationRoute,
      queryParameters: {
        'from_lat': fromLat,
        'from_lng': fromLng,
        'to_lat': toLat,
        'to_lng': toLng,
      },
    );
    final data = response.data as Map<String, dynamic>;
    return RouteEstimate(
      distanceM: _asDouble(data['total_distance_m']),
      durationS: (data['total_duration_s'] as num?)?.toInt() ?? 0,
      isEstimate: data['is_estimate'] == true,
    );
  }

  /// Parses the `stops` sibling, ordered by `sequence`; `[]` when absent.
  static List<RideStop> _parseStops(Object? raw) {
    final stops =
        (raw as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RideStop.fromJson)
        .toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return stops;
  }

  static double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
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
