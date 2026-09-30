---
tag: ratings
depends_on: []
status: open
---

# `GET /driver/ratings` + `GET /rider/ratings` — read back submitted ratings

Implements the **server half of `driver_app_plans/STATUS.md` bug #5** ("Already rated" set is
session-local because `GET /driver/ratings` is a stub) **and the symmetric rider endpoint**
(`GET /rider/ratings`, `router.go:122`), which is currently the same stub. The driver app already
declares `driverRatings` (`driver_app/lib/core/api/endpoints.dart:24`) and tracks rated rides in a
session-local `ratedRideIdsProvider`
(`driver_app/lib/features/rides/presentation/rate_sheet.dart:6-14`) because there is nothing to
read back. Rating *writes* already work for both roles; this plan only adds the **read** endpoints.

**Read first:**

- `internal/router/router.go:144` — `driver.GET("/ratings", platformHandler.StubPayment)`.
- `internal/router/router.go:122` — `rider.GET("/ratings", platformHandler.StubPayment)` (the twin).
- `internal/handler/platform.go:487-501` — `StubPayment`, the `200 {"status":"stub",...}` body both
  routes return today.
- `internal/database/migrations/005_create_rides.up.sql:56-67` — `ratings` table
  (`rater_role IN ('rider','driver')`, `rater_id`, `ratee_id`, `score`, `comment`, `created_at`,
  `UNIQUE(ride_id, rater_role)`); index only on `ratee_id` `:69`.
- `internal/model/ride.go:46-55` — `model.Rating`.
- `internal/repository/ride_repo.go:178-184` — `CreateRating` (the write path).
- `internal/service/ride.go:205-220` — `RideService.Rate` (score 1-5 validation).
- `internal/handler/ride.go:268-302` — `RateRide`, which sets `rater_role = "driver"` when the actor
  is a driver, else `"rider"`, and stamps `rater_id` from the JWT `user_id`.
- `internal/handler/ride.go:159-197` — `GetRideHistory`: the role-aware pagination + envelope
  pattern to mirror (`page`/`per_page` 1-based, `per_page` clamp ≤ 50).
- `internal/handler/respond.go:25,71,140` — `fail` / `bindJSON` / `respondRepo`.

## Current state (verified)

- Both endpoints answer `{"status":"stub","message":"Payment integration pending"}`
  (`platform.go:496-501`) — a wrong-shaped success, which is exactly why neither app adopted it.
- The `ratings` table records everything both apps need (`ride_id`, `score`, `comment`,
  `created_at`), but nothing reads it back and there is **no index on `rater_id`** (only
  `idx_ratings_ratee`), so a rater-scoped query is a full scan.

## Scope

1. **Migration (append-only, next free number — 015 as of writing; re-check before landing).**
   Add `idx_ratings_rater ON ratings(rater_id, rater_role)` so both rater-scoped queries are
   indexed. No schema change to `ratings` (the columns already exist).
2. **Repository.** Add `FindRatingsByRater(raterID, raterRole string, limit, offset int) ([]model.Rating, int, error)`
   to `RideRepository` (`internal/repository/ride_repo.go:13-25`), implement on `RideRepo`
   (`SELECT ... WHERE rater_id=$1 AND rater_role=$2 ORDER BY created_at DESC LIMIT/OFFSET` plus a
   `COUNT(*)`), and **add the method to the `tests/testutil` mock** (invariant: mocks move in
   lockstep; `tests/` boots with mocks, no DB).
3. **Handler.** Implement one role-aware `GetRatings` on `RideHandler` (it already holds `rideRepo`)
   — do **not** grow `StubPayment`/`PlatformHandler`. Read `user_id` + `role` from the context
   exactly as `GetRideHistory` does (`:160-181`), parse `page`/`per_page` (`:163-171`), map the role
   to `rater_role` (`driver` → `'driver'`, else `'rider'`), call the repo, and answer the
   history-shaped envelope:
   ```json
   {"ratings":[{ "id","ride_id","rater_role","score","comment","created_at" }],
    "total":n,"page":1,"per_page":20,"total_pages":n}
   ```
   `ride_id` is the field each app folds into its "already rated" set.
4. **Routes.** Replace `internal/router/router.go:144` with
   `driver.GET("/ratings", rideHandler.GetRatings)` and `:122` with
   `rider.GET("/ratings", rideHandler.GetRatings)`.
5. **Errors.** A repo failure must go through `respondRepo(..., "failed to load ratings")` → 500
   `INTERNAL`, never a false success; `per_page` clamp mirrors history.
6. **Docs/spec.** Swagger annotations on `GetRatings` (both paths); regenerate the spec via the
   existing `cmd/openapi` mechanism. Add short `GET /driver/ratings` + `GET /rider/ratings` entries
   to `RIDER_API_GUIDE.md`.

## Out of scope

- Ratings *received* by a user and the aggregate `drivers.rating_summary` — already surfaced in the
  profile; these endpoints are strictly a user's **submitted** ratings.
- The app-side change to consume the endpoints (build the real `ratedRideIds` from them) belongs to
  `driver-planner`/`rider-planner`; this plan only frees bug #5 server-side. Once landed, drop the
  "kept open" blocker note on bug #5 in `driver_app_plans/STATUS.md`.

## Invariants carried in

- Migrations are append-only; version = numeric prefix before the first `_`; only `*.up.sql` runs.
- Success paths/status codes for valid existing requests never change.
- A read failure is 5xx `INTERNAL`, never a 4xx and never a stub-shaped 200.
- Mocks in `tests/testutil` move in lockstep with the repository interface.
- Pagination stays 1-based `page`/`per_page` (the contract `[history]` already fixed).

## Tests

- `tests/` integration (DB-backed): a driver rates a completed ride, then `GET /driver/ratings`
  returns it with the right `ride_id`/`score` and only this rater's rows; the symmetric
  `GET /rider/ratings` returns the rider's submission; one user does not see another's.
- Role scoping: the same query with `rater_role='rider'` does not leak into the driver response,
  even for the same `ride_id` (the `UNIQUE(ride_id, rater_role)` row pair).
- Pagination: `per_page` clamp and `total_pages`; an out-of-range page returns an empty list, not
  an error.
- Error contract: a repo outage → 500 `INTERNAL` (mock the repo failure).
- `tests/testutil` mock implements the new method so `make test` stays green without Docker.

## Verify

```bash
make test               # unit tests, no DB (mocks)
make lint
make test-integration   # DB-backed
gofmt -w <files> && go vet ./...
```
