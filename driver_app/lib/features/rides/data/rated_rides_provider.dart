import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rides_repository.dart';

/// Ratings per `GET /driver/ratings` request.
///
/// The server clamps `per_page` to 1..50 and **silently rewrites** anything
/// outside that to 20 (`internal/handler/ride.go:421-427`), so asking for more
/// is not "get more", it is "get fewer, silently". 50 is the ceiling.
const int ratedRidesPageSize = 50;

/// Ceiling on the pagination walk so a server that keeps claiming more pages
/// cannot spin the app. 20 pages × 50 = 1000 ratings.
const int ratedRidesMaxPages = 20;

/// Shown in place of the rating prompts when the list could not be loaded.
const String ratedRidesErrorMessage = 'Could not load the rides you rated.';

/// Whether the driver has already rated a ride.
///
/// Tri-state on purpose. The set this replaced was session-local, and every
/// lookup answered `false` while loading *or* on error — so a ride the driver
/// had already rated was offered again on the next cold start. [unknown] is the
/// honest answer when the server list is not on screen, and it is the state a
/// caller must never collapse into [unrated].
enum RatingStatus {
  /// The loaded list contains this ride.
  rated,

  /// The loaded list does not contain this ride. The only state in which the
  /// driver may be asked to rate.
  unrated,

  /// The list has not landed yet, or the load failed.
  unknown;

  /// Whether a rating prompt may be shown. True only for [unrated]: asking a
  /// driver to rate a ride they already rated is the bug this tri-state exists
  /// to make unrepresentable.
  bool get canPrompt => this == RatingStatus.unrated;
}

/// The rides the driver has rated, as the server lists them.
class RatedRides {
  /// Rated ride ids, unmodifiable. A set — not a boolean — because that is the
  /// fact the server hands back and the only thing that can be trusted.
  final Set<String> rideIds;

  /// True when the bounded walk stopped before the server's count, so the ids
  /// here are only the newest slice and an absent ride is **not** evidence it
  /// is unrated. A truncated set answers [RatingStatus.unknown] for any ride it
  /// does not list; [ratedRideStatusProvider] then resolves that one ride with
  /// the server's `ride_id` filter instead of guessing.
  final bool truncated;

  const RatedRides(this.rideIds, {this.truncated = false});

  /// [RatingStatus] for [rideId]. An empty id is [RatingStatus.unknown]: it
  /// belongs to no ride, so nothing is known about it.
  RatingStatus statusOf(String rideId) {
    if (rideId.isEmpty) return RatingStatus.unknown;
    if (rideIds.contains(rideId)) return RatingStatus.rated;
    return truncated ? RatingStatus.unknown : RatingStatus.unrated;
  }
}

/// Loads `GET /driver/ratings` — the set of rides the driver has already rated
/// — so "already rated" survives an app restart instead of living for one
/// session.
///
/// Every row the endpoint returns is a rating the driver submitted: the handler
/// pins `rater_role` from the caller's role
/// (`internal/handler/ride.go:430-435`), so the app does not re-filter.
class RatedRidesNotifier extends AsyncNotifier<RatedRides> {
  /// Rides marked while the server list was not on screen. Merged into every
  /// load, because the response in flight was requested *before* the rating POST
  /// landed and may not list this ride — without the merge the prompt would come
  /// straight back.
  final Set<String> _marked = <String>{};

  /// Cancel tokens for the fetches in flight, cancelled on dispose (see
  /// [build]).
  final Set<CancelToken> _inFlight = <CancelToken>{};

  bool _disposed = false;

  @override
  Future<RatedRides> build() async {
    // Cancelling in-flight requests on dispose is what keeps a torn-down widget
    // tree clean: Dio arms a connect/receive timer per request, and one that is
    // still open when a test ends fails it with "a Timer is still pending even
    // after the widget tree was disposed". This suite has already been bitten by
    // exactly that, so the provider cancels rather than leaks.
    ref.onDispose(_abort);
    try {
      return await _load();
    } catch (_) {
      if (!_disposed) rethrow;
      // Disposed mid-flight (a test that tears its tree down without awaiting
      // the fetch, a sign-out). There is no state left to publish and nobody
      // left to publish it to; rethrowing would push an error onto a provider
      // whose listeners are already gone.
      return RatedRides(Set.unmodifiable(_marked));
    }
  }

  /// Reloads the set, for pull-to-refresh and the retry affordance.
  ///
  /// The loaded list stays readable while the request runs, so a refresh does
  /// not blank every "Rated" label mid-gesture. A *first* load has nothing to
  /// keep, and then the status is [RatingStatus.unknown] until it lands.
  Future<void> refresh() async {
    // One request at a time. A refresh landing while the *first* load is still
    // running is dropped rather than queued: that load is already answering the
    // same question, so a second fetch would only add a request the driver
    // cannot see the effect of.
    if (_disposed || _inFlight.isNotEmpty) return;
    state = AsyncValue<RatedRides>.loading().copyWithPrevious(state);
    final result = await AsyncValue.guard<RatedRides>(_load);
    // `_abort` ran while this was in flight: the provider is gone, so there is
    // no state to write and no screen to show the failure on.
    if (_disposed) return;
    state = result;
  }

  /// Optimistically records that the driver rated [rideId], so the prompt
  /// retires the moment the POST lands instead of after a refetch.
  ///
  /// Additive only: it never replaces the loaded set, and it never turns a
  /// loading or failed state into a loaded one (that would make every other
  /// ride read as unrated).
  void markRated(String rideId) {
    if (rideId.isEmpty || _disposed) return;
    _marked.add(rideId);
    final loaded = state.valueOrNull;
    // Still loading, or failed: `_load` merges `_marked` when it lands.
    if (loaded == null || loaded.rideIds.contains(rideId)) return;
    state = AsyncValue<RatedRides>.data(
      RatedRides(
        Set.unmodifiable({...loaded.rideIds, rideId}),
        truncated: loaded.truncated,
      ),
    );
  }

  /// Every page of the driver's ratings, newest first, up to
  /// [ratedRidesMaxPages].
  Future<RatedRides> _load() async {
    final token = CancelToken();
    _inFlight.add(token);
    try {
      final repo = ref.read(ridesRepositoryProvider);
      final ids = <String>{};
      var page = 1;
      var totalPages = 1;
      var total = 0;
      do {
        final result = await repo.fetchMyRatings(
          page: page,
          perPage: ratedRidesPageSize,
          cancelToken: token,
        );
        for (final rating in result.ratings) {
          if (rating.rideId.isNotEmpty) ids.add(rating.rideId);
        }
        if (result.total > total) total = result.total;
        totalPages = result.totalPages < 1 ? 1 : result.totalPages;
        page++;
      } while (page <= totalPages && page <= ratedRidesMaxPages);
      // Merged *after* the walk, not before: a rating submitted while this was
      // in flight is not in the response, and dropping it would bring the
      // prompt straight back.
      ids.addAll(_marked);
      // The walk stopped short of what the server reported — either more pages
      // than the ceiling allows, or a total the ceiling cannot hold. Absence
      // from the loaded set is then not evidence of "unrated".
      final truncated = totalPages > ratedRidesMaxPages ||
          total > ratedRidesMaxPages * ratedRidesPageSize;
      return RatedRides(Set.unmodifiable(ids), truncated: truncated);
    } finally {
      _inFlight.remove(token);
    }
  }

  void _abort() {
    _disposed = true;
    for (final token in _inFlight) {
      if (!token.isCancelled) token.cancel();
    }
    _inFlight.clear();
  }
}

/// The one source of "has this ride been rated" truth.
final ratedRidesProvider =
    AsyncNotifierProvider<RatedRidesNotifier, RatedRides>(RatedRidesNotifier.new);

/// [RatingStatus] for one ride, derived from [ratedRidesProvider].
///
/// Resolution order, most definitive first:
///  1. the loaded set contains the ride — [RatingStatus.rated],
///  2. the walk was complete and does not contain the ride —
///     [RatingStatus.unrated], the only state in which the driver may be asked,
///  3. the walk truncated — ask the server directly with the `ride_id`
///     existence filter (`GET /driver/ratings?ride_id=<uuid>`): one row is
///     [RatingStatus.rated], zero rows is [RatingStatus.unrated], any failure
///     (including a `422` for a malformed id) is [RatingStatus.unknown].
///
/// A loading walk and a failed walk both fall to [RatingStatus.unknown]; there
/// is no path that turns "not fetched yet" into [RatingStatus.unrated]. This is
/// a [FutureProvider] rather than a plain [Provider] because resolving a ride
/// past the page cap requires a request.
final ratedRideStatusProvider =
    FutureProvider.family<RatingStatus, String>((ref, rideId) async {
  if (rideId.isEmpty) return RatingStatus.unknown;

  final RatedRides loaded;
  try {
    loaded = await ref.watch(ratedRidesProvider.future);
  } catch (_) {
    return RatingStatus.unknown;
  }
  if (loaded.rideIds.contains(rideId)) return RatingStatus.rated;
  if (!loaded.truncated) return RatingStatus.unrated;

  return _resolveRideRating(ref, rideId);
});

/// The server's per-ride answer via `GET /driver/ratings?ride_id=<uuid>`: a
/// definitive [RatingStatus.rated] / [RatingStatus.unrated], or
/// [RatingStatus.unknown] when the request fails — a failure must never read as
/// "unrated", or the driver is prompted to rate a ride they already rated.
Future<RatingStatus> _resolveRideRating(Ref ref, String rideId) async {
  try {
    final page = await ref
        .read(ridesRepositoryProvider)
        .fetchMyRatings(rideId: rideId);
    final rated = page.ratings.any((rating) => rating.rideId == rideId);
    return rated ? RatingStatus.rated : RatingStatus.unrated;
  } catch (_) {
    return RatingStatus.unknown;
  }
}
