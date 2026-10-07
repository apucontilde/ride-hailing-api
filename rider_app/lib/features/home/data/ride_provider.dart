import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/api/api_exceptions.dart';
import '../../../core/api/endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../model/fare.dart';
import '../model/ride_detail.dart';

/// How the last `POST /rides/{id}/rate` ended.
///
/// [RatingOutcome.alreadyRated] is a SUCCESS from the rider's point of view —
/// the rating is on file either way — so the UI closes the prompt instead of
/// showing a failure banner over a ride the rider already scored.
enum RatingOutcome { none, submitted, alreadyRated, failed }

/// Whether one ride has already been rated, as the server can prove it.
///
/// Mirrors `driver_app/lib/features/rides/data/rated_rides_provider.dart`. The
/// set this replaced answered "not rated" for every lookup while the seed was
/// loading, failed, or truncated (past the 1000-row walk bound) — so an ancient
/// rated ride could be offered again. [unknown] is the honest answer when the
/// server truth for this ride is not in hand, and it must never collapse into
/// [unrated]. Since the API grew a `ride_id` existence filter, a ride outside
/// the fetched window is resolved directly instead of guessed.
enum RatingStatus {
  /// The server (or the seeded list) says this ride is rated.
  rated,

  /// The server definitively says this ride is not rated. The only state in
  /// which a rating prompt may be shown.
  unrated,

  /// The server truth has not landed, the load failed, or a truncated seed
  /// could not be resolved for this ride.
  unknown;

  /// Whether a rating prompt may be shown. True only for [unrated].
  bool get canRate => this == RatingStatus.unrated;
}

class RideDetailState {
  final bool loading;
  final RideDetail? detail;
  final Fare? receipt;
  final bool isRating;
  final RatingOutcome rating;

  /// The ride [rating] is about, or null before the first submit.
  ///
  /// [rating] is transient feedback for the UI; this pins it to the ride it
  /// belongs to so a stale outcome can never be read as another ride's.
  final String? ratingRideId;
  final String? error;
  final Set<String> ratedRideIds;

  const RideDetailState({
    this.loading = false,
    this.detail,
    this.receipt,
    this.isRating = false,
    this.rating = RatingOutcome.none,
    this.ratingRideId,
    this.error,
    this.ratedRideIds = const {},
  });

  RideDetailState copyWith({
    bool? loading,
    RideDetail? detail,
    Fare? receipt,
    bool? isRating,
    RatingOutcome? rating,
    String? ratingRideId,
    String? error,
    Set<String>? ratedRideIds,
  }) {
    return RideDetailState(
      loading: loading ?? this.loading,
      detail: detail ?? this.detail,
      receipt: receipt ?? this.receipt,
      isRating: isRating ?? this.isRating,
      rating: rating ?? this.rating,
      ratingRideId: ratingRideId ?? this.ratingRideId,
      error: error,
      ratedRideIds: ratedRideIds ?? this.ratedRideIds,
    );
  }

  /// Whether [rideId] can still be rated from this notifier's session-local
  /// state: nothing is in flight and this ride is not already known-rated here
  /// (seeded from `GET /rider/ratings`, or recorded after a successful POST /
  /// a swallowed 409).
  ///
  /// This is **not** the seed-honesty gate. The authoritative per-ride answer
  /// (server truth, with loading/failure/truncation resolved to `unknown`) is
  /// [riderRideRatingStatusProvider]; the prompt consults that and uses this
  /// only for the in-session double-submit guard.
  ///
  /// Deliberately **ride-scoped**: [rating] is only the transient outcome of
  /// the last submit and must never gate a different ride. A global
  /// `rating == submitted` check would silently kill the prompt for every ride
  /// completed after the first one rated in the session.
  bool canRate(String rideId) => !isRating && !ratedRideIds.contains(rideId);
}

/// Ride detail, receipt and rating (LC-3).
///
/// Owns the three ride-scoped reads/writes behind `GET /rides/{id}`,
/// `GET /rides/{id}/receipt` and `POST /rides/{id}/rate` so no screen has to
/// hand-roll Dio calls. The rating path is the only place that guards a double
/// submit — the backend has **no** `completed`/party check, so this notifier is
/// the whole contract (see `rider_app_plans/[tracking]_ride_detail_receipt_rating.md`).
class RideDetailNotifier extends StateNotifier<RideDetailState> {
  RideDetailNotifier(this._apiClient) : super(const RideDetailState());

  final ApiClient _apiClient;
  bool _disposed = false;

  /// `GET /rides/{id}` — the authoritative ride object.
  Future<RideDetail?> fetchRide(String rideId) async {
    state = state.copyWith(loading: true);
    try {
      final response = await _apiClient.dio.get(ApiEndpoints.rideById(rideId));
      final ride = (response.data as Map<String, dynamic>?)?['ride'];
      if (ride is! Map<String, dynamic>) {
        _write(state.copyWith(loading: false, error: 'Ride not found'));
        return null;
      }
      final detail = RideDetail.fromJson(ride);
      _write(state.copyWith(loading: false, detail: detail));
      return detail;
    } on DioException catch (e) {
      _write(state.copyWith(
        loading: false,
        error: apiErrorMessage(e, 'Failed to load ride'),
      ));
      return null;
    } catch (e) {
      _write(state.copyWith(loading: false, error: e.toString()));
      return null;
    }
  }

  /// `GET /rides/{id}/receipt` — the fare breakdown, same five numbers the WS
  /// `fare` payload carries.
  Future<Fare?> fetchReceipt(String rideId) async {
    try {
      final response = await _apiClient.dio.get(ApiEndpoints.receipt(rideId));
      final receipt = (response.data as Map<String, dynamic>?)?['receipt'];
      if (receipt is! Map<String, dynamic>) {
        _write(state.copyWith(error: 'Receipt unavailable'));
        return null;
      }
      final fare = Fare.fromJson(receipt);
      _write(state.copyWith(receipt: fare));
      return fare;
    } on DioException catch (e) {
      _write(state.copyWith(
        error: apiErrorMessage(e, 'Failed to load receipt'),
      ));
      return null;
    }
  }

  /// The fare to show on completion: the WS `fare` payload when it arrived,
  /// otherwise `GET /rides/{id}/receipt`, cached in [RideDetailState.receipt].
  Future<Fare?> resolveFare(String rideId, {Fare? wsFare}) async {
    if (wsFare != null) return wsFare;
    if (state.receipt != null) return state.receipt;
    return fetchReceipt(rideId);
  }

  /// `POST /rides/{id}/rate`.
  ///
  /// Returns the outcome for [rideId] itself so the caller never has to infer
  /// it from the shared [RideDetailState.rating] (which belongs to whichever
  /// ride was submitted last).
  ///
  /// Three guards, in order:
  ///  * a second submit while one is in flight is dropped (the backend would
  ///    take it and answer a duplicate-conflict);
  ///  * a ride already in [RideDetailState.ratedRideIds] is never re-sent — the
  ///    set is seeded from `GET /rider/ratings`;
  ///  * a 409 CONFLICT (the correct mapping of the `UNIQUE(ride_id, rater_role)`
  ///    violation) resolves to [RatingOutcome.alreadyRated], not a failure.
  Future<RatingOutcome> rateRide(String rideId, int score,
      {String comment = ''}) async {
    if (state.isRating) return RatingOutcome.none;
    if (state.ratedRideIds.contains(rideId)) {
      _write(state.copyWith(
        rating: RatingOutcome.alreadyRated,
        ratingRideId: rideId,
      ));
      return RatingOutcome.alreadyRated;
    }
    _write(state.copyWith(
      isRating: true,
      rating: RatingOutcome.none,
      ratingRideId: rideId,
    ));
    try {
      await _apiClient.dio.post(
        ApiEndpoints.rateRide(rideId),
        data: {'score': score, 'comment': comment},
      );
      _write(state.copyWith(
        isRating: false,
        rating: RatingOutcome.submitted,
        ratingRideId: rideId,
        ratedRideIds: {...state.ratedRideIds, rideId},
      ));
      return RatingOutcome.submitted;
    } on DioException catch (e) {
      if (e.response?.statusCode == 409) {
        _write(state.copyWith(
          isRating: false,
          rating: RatingOutcome.alreadyRated,
          ratingRideId: rideId,
          ratedRideIds: {...state.ratedRideIds, rideId},
        ));
        return RatingOutcome.alreadyRated;
      }
      _write(state.copyWith(
        isRating: false,
        rating: RatingOutcome.failed,
        ratingRideId: rideId,
        error: apiErrorMessage(e, 'Failed to submit your rating'),
      ));
      return RatingOutcome.failed;
    }
  }

  /// Seeds the already-rated set from `GET /rider/ratings` so a completed ride
  /// the rider scored on another device (or in a previous session) is not
  /// re-prompted.
  void seedRatedRideIds(Set<String> rideIds) {
    if (rideIds.isEmpty) return;
    _write(state.copyWith(ratedRideIds: {...state.ratedRideIds, ...rideIds}));
  }

  void reset() {
    _write(const RideDetailState());
  }

  void _write(RideDetailState next) {
    if (_disposed) return;
    state = next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

final rideDetailProvider =
    StateNotifierProvider<RideDetailNotifier, RideDetailState>((ref) {
  return RideDetailNotifier(ref.read(apiClientProvider));
});

/// The `GET /rider/ratings` page size. The handler caps `per_page` at 50
/// (`internal/handler/ride.go:GetRatings`), so asking for more is pointless.
const int ratedRideIdsPageSize = 50;

/// Safety bound on the seed walk: a malformed `total_pages` must not turn this
/// into an unbounded loop. 20 pages × 50 = 1000 rated rides, the same ceiling
/// `driver_app/lib/features/rides/data/rated_rides_provider.dart` uses.
const int ratedRideIdsMaxPages = 20;

/// The rated ride ids a seed walk collected, plus whether it was cut short.
///
/// [partial] is true when the envelope's `total` exceeds what the bounded walk
/// can hold ([ratedRideIdsMaxPages] × [ratedRideIdsPageSize]); the ids in
/// [rideIds] are then only the newest slice and absence of a ride is **not**
/// evidence it is unrated.
class RatedRideSeed {
  final Set<String> rideIds;
  final bool partial;

  const RatedRideSeed(this.rideIds, {this.partial = false});
}

/// The ride ids this rider has already rated, from every page of
/// `GET /rider/ratings` (`internal/handler/ride.go:GetRatings`), as a fast path.
///
/// Walking only page 1 would let a rider with more than [ratedRideIdsPageSize]
/// ratings be re-prompted for an old ride. The walk stays bounded; when it
/// truncates, [RatedRideSeed.partial] tells [riderRideRatingStatusProvider] to
/// resolve a specific ride with the server's `ride_id` filter instead of
/// treating its absence as "unrated".
final riderRatedRideIdsProvider = FutureProvider<RatedRideSeed>((ref) async {
  final dio = ref.read(apiClientProvider).dio;
  final ids = <String>{};
  var page = 1;
  var totalPages = 1;
  var total = 0;
  do {
    final response = await dio.get(
      ApiEndpoints.riderRatings,
      queryParameters: {
        'per_page': ratedRideIdsPageSize,
        'page': page,
      },
    );
    final data = response.data as Map<String, dynamic>?;
    final ratings = data?['ratings'] as List<dynamic>? ?? const [];
    for (final json in ratings.whereType<Map<String, dynamic>>()) {
      final id = json['ride_id'] as String?;
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    // `total` is the server's count for the whole (unfiltered) list; the
    // largest one seen is the honest denominator for the truncation check.
    final reportedTotal = data?['total'];
    if (reportedTotal is int && reportedTotal > total) total = reportedTotal;
    // `total_pages` is authoritative; 0/absent (empty history) means one page.
    final reported = data?['total_pages'];
    totalPages = reported is int && reported > 0 ? reported : 1;
    page++;
  } while (page <= totalPages && page <= ratedRideIdsMaxPages);
  final truncated = total > ratedRideIdsMaxPages * ratedRideIdsPageSize;
  return RatedRideSeed(Set.unmodifiable(ids), partial: truncated);
});

/// Whether [rideId] has already been rated, the one source of truth for the
/// completion prompt.
///
/// Resolution order, most definitive first:
///  1. a rating submitted (or a 409 swallowed) in this session — [rated],
///  2. the seeded list contains the ride — [rated],
///  3. the seed is complete and does not contain the ride — [unrated],
///  4. the seed was truncated — ask the server directly with the `ride_id`
///     existence filter (`GET /rider/ratings?ride_id=<uuid>`): one row is
///     [rated], zero rows is [unrated], any failure is [unknown].
///
/// Loading the seed and a failed seed both fall to [unknown]; there is no path
/// that turns "not fetched yet" into [unrated].
final riderRideRatingStatusProvider =
    FutureProvider.family<RatingStatus, String>((ref, rideId) async {
  if (rideId.isEmpty) return RatingStatus.unknown;

  // A rating recorded in this session is definitive even before the seed list
  // reflects it (the seed response may have been requested before the POST).
  final ratedInSession =
      ref.watch(rideDetailProvider.select((state) => state.ratedRideIds));
  if (ratedInSession.contains(rideId)) return RatingStatus.rated;

  final RatedRideSeed seed;
  try {
    seed = await ref.watch(riderRatedRideIdsProvider.future);
  } catch (_) {
    return RatingStatus.unknown;
  }
  if (seed.rideIds.contains(rideId)) return RatingStatus.rated;
  if (!seed.partial) return RatingStatus.unrated;

  return _resolveRideRating(ref, rideId);
});

/// The server's per-ride answer via `GET /rider/ratings?ride_id=<uuid>`: a
/// definitive [RatingStatus.rated] / [RatingStatus.unrated], or [unknown] when
/// the request fails (including a `422` for a malformed id, which the app must
/// never read as unrated).
Future<RatingStatus> _resolveRideRating(Ref ref, String rideId) async {
  try {
    final response = await ref.read(apiClientProvider).dio.get(
      ApiEndpoints.riderRatings,
      queryParameters: {'ride_id': rideId},
    );
    final data = response.data as Map<String, dynamic>?;
    final ratings = data?['ratings'] as List<dynamic>? ?? const [];
    final rated = ratings
        .whereType<Map<String, dynamic>>()
        .any((json) => (json['ride_id'] as String?) == rideId);
    return rated ? RatingStatus.rated : RatingStatus.unrated;
  } catch (_) {
    return RatingStatus.unknown;
  }
}
