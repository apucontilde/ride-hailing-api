---
tag: rides
depends_on: []
status: open
---

# [rides] Create-ride top-level pickup/dropoff coordinate bounds

Closes `api_plans/STATUS.md` known bug **#23**. Two independent defects in the same
struct: a legitimate `0` is rejected, and an out-of-range value is accepted.

## Current state (verified 2026-10-04)

`internal/handler/ride.go:32-36` binds all four top-level coordinates as plain `float64`
with `binding:"required"`:

```go
PickupLat  float64 `json:"pickup_lat" binding:"required"`
PickupLng  float64 `json:"pickup_lng" binding:"required"`
DropoffLat float64 `json:"dropoff_lat" binding:"required"`
DropoffLng float64 `json:"dropoff_lng" binding:"required"`
```

- **`0` is rejected.** go-playground's `required` on a `float64` means "non-zero", so a
  legitimate equatorial / prime-meridian coordinate (e.g. `pickup_lat: 0`) is treated as
  missing and answered `422 VALIDATION_ERROR` ("Invalid Pick-up latitude") by `bindJSON`
  (`internal/handler/respond.go:85-98`).
- **No range check on the top level.** `CreateRide` (`internal/handler/ride.go:103-173`)
  passes the four values straight to `BuildItinerary` (`:136`) and `RequestRide`
  (`:155-159`). `BuildItinerary` range-checks only `reqStops`
  (`internal/service/ride.go:178-183`); the top-level dropoff it appends at
  `internal/service/ride.go:195-201` is unchecked. `RequestRide` forwards them to
  `fareService.CalculateEstimate` (`internal/service/ride.go:217`) → `GetRoute`
  (`internal/service/fare.go:29-33`), which does no bound check, and then persists them
  verbatim to `rides.pickup_*`/`rides.dropoff_*` (`internal/service/ride.go:222-238`). So
  `{"dropoff_lat": 999, ...}` is accepted `201` and written to the DB. The same is true of
  **pickup** — the task's "and pickup — verify" checks out: `pickup_lat`/`pickup_lng` are
  equally unguarded.
- **Contrast (the standard to match).** Stop coordinates use `*float64` so presence and `0`
  are distinguishable, with explicit range checks (`internal/handler/ride.go:60-70`;
  `internal/service/ride.go:178-183`). `PUT /api/v1/rides/:id/destination` uses
  `*float64` + an explicit range check (`internal/handler/ride.go:292`).
- **Multi-stop invariant.** The top-level dropoff is unconditionally appended as the sole
  `kind='destination'` row (`internal/service/ride.go:193-201`), so
  `rides.dropoff_* == last kind='destination' row` holds by construction. This plan must not
  disturb it.

## Scope

1. Make literal `0` a valid coordinate for `pickup_lat`/`pickup_lng`/`dropoff_lat`/
   `dropoff_lng`. Preferred shape: change the four fields to `*float64` and do the
   presence + range check in `CreateRide`, mirroring `changeDestinationRequest`
   (`internal/handler/ride.go:73-79`) and `stopRequest` (`:60-70`). A custom validator tag
   is an acceptable alternative if it keeps `bindJSON`'s human field-name message; do **not**
   leave `binding:"required"` on the number.
2. Range-check all four to the same standard as stops: `lat ∈ [-90, 90]`,
   `lng ∈ [-180, 180]`. Reject with `422 VALIDATION_ERROR`, a public human `message`
   (e.g. `"Pick-up latitude out of range"` / `"Drop-off longitude out of range"`), and the
   cause attached via `fail(c, ..., err)` — `message` is public and must never be
   `err.Error()` (`internal/handler/respond.go:18-32`).
3. Reuse one bound-check helper across the top-level check, the `PUT /destination` check
   (`internal/handler/ride.go:292`) and `BuildItinerary` (`internal/service/ride.go:178-183`)
   so a fourth copy of `-90/90/-180/180` is not created.
4. Preserve `bindJSON` semantics: a truly absent coordinate stays `422` naming the field;
   malformed JSON stays `400 BAD_REQUEST`.
5. Confirm (do not redesign) the invariant `rides.dropoff_* == last kind='destination' row`
   — `BuildItinerary` ordering is unchanged.

**No schema change is needed.** `rides.pickup_*`/`dropoff_*` are numeric and already store
`0`; migrations are append-only and none is added here.

## Invariants carried in

- **Valid-request behavior is unchanged**: a well-formed create still answers `201`; the
  response shape and the stops/destination ordering are untouched.
- Validation failure is `422 VALIDATION_ERROR`; the public `message` is human, the real
  cause is attached (`c.Error`) and never leaked (`internal/handler/respond.go:18-32`).
- `rides.dropoff_* == last kind='destination' row` (`api_plans/STATUS.md` → Landed [multi]).
- Migrations are append-only; none required.
- Mocks in `tests/testutil` move in lockstep — a mock create path must keep accepting the
  same request bodies.

## Verification

```bash
make test
gofmt -w internal/handler/ride.go internal/handler/respond.go internal/service/ride.go
go vet ./...
make lint
make test-integration   # if a DB-backed create assertion is added
```

Tests to add (table-driven where the existing suite is, e.g. `tests/multi_stop_test.go`,
`internal/handler/respond_test.go`):

- `dropoff_lat: 0, dropoff_lng: 0` → `201`, and the persisted `rides.dropoff_*` read back as
  `0` (proves `0` survives bind + DB).
- `999` / `-181` / `-91` on each of pickup/dropoff → `422 VALIDATION_ERROR` with the human
  message and a non-nil logged cause.
- An omitted coordinate → still `422` naming the field (the `0`-is-valid change must not
  turn "absent" into `0`).
- The existing multi-stop cases (valid itinerary; stop range messages) stay green.

## Cross-domain notes

- No Flutter change required: both apps send numeric coordinates and never relied on
  `0` being rejected. This only widens accepted input and adds a bound check.
- `internal/handler/respond.go:137-139` and `internal/handler/ride.go` comments describe the
  old behavior only where relevant; the range-check helper should carry a short comment
  explaining why pointers are used (presence vs `0`).
