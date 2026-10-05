---
tag: history
depends_on: []
status: open
---

# [history] Per-ride rating existence / unbounded ratings walk

## Current state (verified 2026-10-04)

One handler serves both roles:

- `GET /api/v1/rider/ratings` — `internal/router/router.go:181`
- `GET /api/v1/driver/ratings` — `internal/router/router.go:203`
- both bind `rideHandler.GetRatings` — `internal/handler/ride.go:427-473`

`GetRatings` today:

- `page` default 1 (`<1` → 1) — `internal/handler/ride.go:431,433-435`
- `per_page` default 20; **out-of-range is silently rewritten to 20, not clamped to 50** —
  `internal/handler/ride.go:432,436-438`. So 50 is the real ceiling.
- **Offset pagination only; no cursor** — `offset := (page - 1) * perPage`
  `internal/handler/ride.go:439`
- role → `raterRole` (`rider`/`driver`) — `internal/handler/ride.go:441-444`
- envelope `{ratings, total, page, per_page, total_pages}` — `internal/handler/ride.go:464-472`

Repo `FindRatingsByRater(raterID, raterRole, limit, offset)` — `internal/repository/ride_repo.go:351-370`:

- `COUNT(*)` by `rater_id` + `rater_role` — `:356-359`
- `SELECT * … WHERE rater_id = $1 AND rater_role = $2 ORDER BY created_at DESC LIMIT $3 OFFSET $4`
  — `:363-365`
- **No `ride_id` filter and no keyset cursor.** Backed by `idx_ratings_rater` (migration
  `015_ratings_rater_index.up.sql`).

### Why this matters (the twin consumers)

Both apps seed an "already rated" set by walking this endpoint 20 pages × 50 = **1000** rows,
then stop. A user past 1000 submitted ratings has an older rated ride absent from the loaded
set, so it reads as `unrated` and they are re-prompted:

- rider `rider_app_plans/[history]_rated_seed_past_cap.md` (rider bug #11)
- driver `driver_app_plans/[history]_rated_pagination_past_cap.md` (driver bug #10)
- rider walk `rider_app/lib/features/home/data/ride_provider.dart:232-272` (`:239,270`)
- driver walk `driver_app/lib/features/rides/data/rated_rides_provider.dart:15,156`

Both apps' interim honesty fix (truncated ⇒ `unknown`, never `unrated`) is theirs and does not
require this plan. This plan is the **clean fix** that makes the bound disappear: answer the
actual question ("did *this* user rate *this* ride?") without walking a bounded list.

## Scope

Pick the smallest change that answers the per-ride question; keep the list endpoint's existing
shape for current clients.

1. **`ride_id` existence filter (recommended, minimal).** Accept optional `ride_id` on both
   routes: `GET /{rider,driver}/ratings?ride_id=<uuid>`. Repo adds `AND ride_id = $3` when set.
   A known `ride_id` returns 0 or 1 row, so the app resolves `rated`/`unrated` definitively
   instead of inferring from a truncated seed. Envelope shape unchanged (`total` becomes 0/1).
   - Add the param to the swagger godoc (`internal/handler/ride.go:421-426`).
   - Add a repo test (filter returns the row for the rater, and only that rater) and a handler
     test (passes the param through; no param preserves today's list behavior).
2. **Keyset cursor (general fix, larger).** `?before=<created_at,id>` (or an opaque `cursor`)
   ordered by `(created_at DESC, id DESC)` so a walk is not count-bounded; keep `page`/`per_page`
   for back-compat. Use only if product wants full history seeding / a list beyond 1000.
3. **`GET /{rider,driver}/ratings/ids` unpaginated id list.** Cheapest for the seed use-case, but
   the response is unbounded in the number of ratings; only if the list is small by policy, or
   gated with a sane cap + documented bound.

Recommendation: **1** — it matches how the apps actually guard a prompt (`canRate` / `canPrompt`
for one ride) and makes the 1000 cap irrelevant for correctness. Keep the existing seed walk as
a fast path; use the filter to resolve only rides outside the fetched window.

## Invariants carried in

- Valid existing requests keep the same response shape and status; the `per_page` behavior for
  in-range input is unchanged. Do not change the offset semantics for existing callers.
- One handler serves both roles — a fix here lands for rider and driver together; do not split
  into two endpoints unless a role genuinely needs a different contract.
- The apps' rule stands: `unknown` must never read as `unrated`; loading/error/truncated stays
  `unknown`. This plan lets a known ride be resolved to `rated`/`unrated`; it does not license a
  false `unrated`.
- Do not remove the `idx_ratings_rater` path; keep the query sargable.

## Verification

```bash
go test -count=1 ./...
make test-integration   # SQL against PostGIS
make lint
```

New coverage: repo filter returns exactly the rater's rating for a given `ride_id` (and nothing
for another user's); handler forwards `ride_id` and keeps the no-param list contract; if a cursor
lands, a walk past the old 1000 bound is exercised. Swagger regenerated if the param is added.

## Cross-domain notes

- Opening this plan renumbers both twins to depend on it:
  `rider_app_plans/01_[history]_rated_seed_past_cap.md` and
  `driver_app_plans/01_[history]_rated_pagination_past_cap.md`, each
  `depends_on: ["[history]_rating_existence_endpoint.md"]`.
- The rider plan's option (1) (client-only `total`-based truncation honesty) and the driver
  plan's option (1) (truncated flag ⇒ `unknown`) are **independent** and may land before this.
  When this lands, they can resolve `unknown` for a specific ride via the filter while keeping
  `unknown` for loading/error.
- Any server change must be reflected to `rider-planner` **and** `driver-planner` (shared
  endpoint, shared contract).
