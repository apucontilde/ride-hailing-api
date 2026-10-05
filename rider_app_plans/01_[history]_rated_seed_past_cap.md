---
tag: history
depends_on: ["[history]_rating_existence_endpoint.md"]
status: open
---

# [history] Already-rated seed stops at 1000

## Current state (verified 2026-10-04)

`rider_app/lib/features/home/data/ride_provider.dart:232-272` `riderRatedRideIdsProvider` walks
every page of `GET /rider/ratings` with `ratedRideIdsPageSize = 50` (`:234`) and stops at
`ratedRideIdsMaxPages = 20` (`:239`; loop condition `:270`). 20 × 50 = **1000** rated rides.

Server contract — `internal/handler/ride.go:427-473` `GetRatings`:
- `per_page` is clamped: `<1` or `>50` is silently rewritten to 20 (`:436-438`), so 50 is the
  real ceiling.
- Offset pagination only (`page`, `per_page`); **no cursor**.
- The envelope returns `total` (`:468`) and `total_pages` (`:471`); the app reads only
  `total_pages` (`ride_provider.dart:267-268`).

So a rider with more than 1000 ratings has a **truncated** seed. A completed ride older than the
newest 1000 can be re-prompted; today that is non-fatal because the prompt's `409 CONFLICT` maps
to `alreadyRated` (`ride_provider.dart:184-192`).

The deeper honesty gap: the rider `canRate` guard is a plain `bool` (`ride_provider.dart:73`),
and the seed is applied through `seedRatedRideIds` (`:206-209`) only after the walk resolves
(`active_ride_screen.dart:142-149`). While the seed is loading, failed, **or truncated**,
`ratedRideIds` is (partly) empty, so `canRate` returns true — i.e. the app can claim **unrated**
for a ride whose truth is merely **unfetched**. `_seedRatedRideIds` swallows the failure
(`active_ride_screen.dart:146-148`), so a failed walk is indistinguishable from "no ratings".

The driver app already models this correctly:
`driver_app/lib/features/rides/data/rated_rides_provider.dart` has the tri-state
`RatingStatus{rated,unrated,unknown}` (`:27-58`) with `canPrompt` true only for `unrated`, and the
same 1000 ceiling is documented there (`:13-15`). The rider domain has no `unknown` state.

## Scope

Close the bound honestly, in this order:

1. **Client-only honesty (minimal, no server change).** The envelope already carries `total`
   (`ride.go:468`), so the provider can detect truncation without a new endpoint:
   `total > ratedRideIdsMaxPages * ratedRideIdsPageSize` ⇒ the seed is **partial**. Introduce a
   rider tri-state mirroring the driver (`RatingStatus{rated,unrated,unknown}`) where
   loading / failure / partial all resolve to `unknown`, and `canRate` becomes true only for
   `unrated`. Consequence: a rider past the ceiling is never wrongly re-prompted; the cost is
   that a ride beyond the fetched window is `unknown` (not prompted) rather than `unrated`. This
   is the honest trade — the 409 backstop already makes a wrong prompt harmless-but-wrong.
2. **Real fix (needs server support).** Either return all rated ride ids unpaginated (e.g.
   `GET /rider/ratings/ids`), or raise/remove the 50-cap, or add a cursor (`before`/`after`) so
   the walk is not count-bounded. `GetRatings` is the server side, so this is an **`api_plans/`
   prerequisite** — record it there rather than assuming a cursor the handler does not serve.
3. Investigate a per-ride answer instead of seeding a set: nothing in `RideDetail`
   (`features/home/model/ride_detail.dart`) exposes rating state today, so an "is this ride
   rated" lookup on `GET /rides/:id` would also be a server addition.

Recommendation: ship (1) now — it makes the existing bound honest and removes the
unfetched ⇒ unrated violation with no server change. Schedule (2) under `api_plans/` only if
product wants unlimited history seeding.

## Invariants carried in

- **Never claim `unrated` for a ride that is actually rated when the truth is merely unfetched** —
  the tri-state / `unknown` rule (`driver_app/.../rated_rides_provider.dart:20-58`). The rider
  `canRate` bool must not be reachable from a loading / failed / partial seed.
- A `409` from `POST /rides/:id/rate` stays `alreadyRated` (success), not a failure
  (`ride_provider.dart:184-192`).
- If a ceiling remains, it stays documented in the code.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Extend `rider_app/test/features/home/data/ride_provider_test.dart` (existing group at `:435`, and
the lying-`total_pages` test at `:554`): truncation (`total` > 1000) ⇒ `unknown`, not `unrated`;
loading / failure ⇒ `unknown`; a found id ⇒ `rated`; a genuinely short complete list ⇒ `unrated`.

## Cross-domain notes

- (2) needs an open `api_plans/` plan on `internal/handler/ride.go` `GetRatings`; name it there
  before implementing a cursor. That prerequisite is now open:
  `api_plans/[history]_rating_existence_endpoint.md` (recommended shape: a `ride_id` existence
  filter on `GET /{rider,driver}/ratings`, which answers "did I rate this ride" directly and
  makes the 1000 seed bound irrelevant for correctness). This plan is `01_` because its
  `depends_on` names that open plan.
- Step (1) (client-only `total`-based truncation honesty) is **independent** of the API
  prerequisite and may land first; this plan's honesty fix does not wait on the server.
- The driver app shares the same 1000 ceiling and **already** has the tri-state; any server cursor
  change should be reflected to `driver-planner` (cross-app). Driver twin:
  `driver_app_plans/01_[history]_rated_pagination_past_cap.md`.
