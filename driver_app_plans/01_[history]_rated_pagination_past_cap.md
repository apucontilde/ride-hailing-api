---
tag: history
depends_on: ["[history]_rating_existence_endpoint.md"]
status: open
---

# [history] Rated-rides walk past the 1000 cap

## Current state

`RatedRidesNotifier._load()` walks `GET /driver/ratings` page by page and stops when either the
server's `total_pages` is exhausted **or** `ratedRidesMaxPages` is hit:

- `ratedRidesPageSize = 50` — `driver_app/lib/features/rides/data/rated_rides_provider.dart:11`
- `ratedRidesMaxPages = 20` (20 × 50 = 1000) — `rated_rides_provider.dart:15`
- loop `while (page <= totalPages && page <= ratedRidesMaxPages)` — `rated_rides_provider.dart:156`
- `_load()` body — `rated_rides_provider.dart:137-165`; `DriverRatingPage` already parses the
  envelope (`total`, `page`, `per_page`, `total_pages`) — `driver_app/lib/features/rides/data/rides_repository.dart:69-86,197,200`
- request — `rides_repository.dart:186`; endpoint `driver_app/lib/core/api/endpoints.dart:24`

Server side (`internal/handler/ride.go` `GetRatings`):

- clamps `per_page` to 1..50, silently rewriting out-of-range to **20** — `internal/handler/ride.go:436-438`
- returns the authoritative `total` and `total_pages` — `internal/handler/ride.go:464-471`
- **no** `ride_id` filter and **no** cursor; `FindRatingsByRater` is `(raterID, raterRole, perPage, offset)` only — `internal/handler/ride.go:446`, `internal/repository/ride_repo.go:351-370`

Consequence: a driver with **more than 1000** submitted ratings has a newest-first window only. An
older already-rated ride is absent from the loaded set, so `RatedRides.statusOf` returns
`unrated` (`rated_rides_provider.dart:54-57`) and the driver is prompted again. This is driver
bug #10 (`driver_app_plans/STATUS.md`), the **symmetric twin** of rider bug #11
(`rider_app_plans/STATUS.md:193`): `riderRatedRideIdsProvider`
(`rider_app/lib/features/home/data/ride_provider.dart:239,247-271`) walks the same handler with the
same 20 × 50 bound. Both apps hit one server endpoint; a fix to the endpoint fixes both.

**Drift:** the provider's own doc comment cites the clamp at `internal/handler/ride.go:421-427`
(`rated_rides_provider.dart:9`) — that range is the `GetRatings` godoc; the real clamp is
`:436-438`.

## Scope

The cap is a **documented bound, not a silent lie** only if a truncated set can never read as
`unrated`. Two options; the plan lands the honesty fix regardless, and records the API work as a
prerequisite rather than assuming it.

1. **App-only honesty fix (no API change, recommended to land first).** Carry a `truncated` flag on
   `RatedRides`: set it when `totalPages > ratedRidesMaxPages` (the walk stopped short of what the
   server reported). `statusOf(rideId)` then returns `unknown` — never `unrated` — for any ride not
   in a truncated set, and `canPrompt` stays true only for a genuinely complete list. This makes the
   bound honest at the cost of suppressing an old prompt (safe: better to not ask than to ask twice).
   `markRated`'s optimistic merge must carry the flag through.
2. **Raise the walk to `total_pages`.** Already possible with no server change — `total_pages` is
   authoritative and parsed. Cost is N sequential requests (2 per 100 ratings; ~100 requests at
   5,000 ratings). Acceptable only if paired with the same `truncated` honesty state for any retained
   hard ceiling, plus an empty-page short-circuit. Not the default.

**Clean fix / cross-domain prerequisite (now open):** one request should answer "has this ride
been rated". Add a `ride_id` filter to `GET /rider/ratings` + `GET /driver/ratings`, or an
existence endpoint (`GET /driver/rides/:id/rating`). This is the `api_plans/` prerequisite
`api_plans/[history]_rating_existence_endpoint.md` (recommended shape: the `ride_id` existence
filter; a keyset cursor is the larger alternative). This plan is `01_` because its `depends_on`
names that open plan. Option 1 (app-only honesty) is **independent** of it and may land first;
until the server lands, option 1 is the honest behavior.

## Invariants carried in

- `unknown` must never read as `unrated`: a truncated/failed/loading set suppresses prompts; only a
  complete set that provably lacks the ride may prompt (`rated_rides_provider.dart:20-41`).
- A bounded walk is a documented bound, not a silent lie — surface truncation in the type, do not
  let the ceiling masquerade as the full set.
- The ride-state machine owns the primary button; widgets never hold paging state.
- Do not remove public providers consumed by History/Trip; extend them (`ratedRideStatusProvider`
  consumers: `rides_history_screen.dart:199,241,255`, `trip_screen.dart:177,181`).

## Cross-domain notes

- Symmetric rider bug #11; any server-side fix must serve both `/rider/ratings` and
  `/driver/ratings` (same handler, same repo), so it is one API prerequisite, not two.
- No Dart code changes outside `driver_app/lib/features/rides/` and its tests; no `shared/` change.
- Keep the API prerequisite in `api_plans/` (other domain) — this plan only references it.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Expected new coverage in `driver_app/test/features/rides/data/rated_rides_provider_test.dart`:
a walk that reports `total_pages > ratedRidesMaxPages` marks the set truncated and yields
`RatingStatus.unknown` (never `unrated`) for a ride outside the window; a complete set still yields
`unrated` for an absent ride and `canPrompt == true`; the walk still stops at the ceiling.
