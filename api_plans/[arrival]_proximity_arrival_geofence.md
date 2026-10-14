---
tag: arrival
depends_on: ["landed geo driver-location hot path + [tracking] actuals (STATUS.md)"]
status: open
---

# Proximity arrival geofence — server-owned auto-advance + nearby notification

**Chain head (unnumbered).** `depends_on` names *landed* capability — the geo driver-location hot
path (`internal/handler/geo.go`, pre-history) and the `[tracking]` actuals (`ride_track_points`,
migration 021, `STATUS.md` → Landed `[tracking]`), not an open plan — so the file is
`[arrival]_proximity_arrival_geofence.md` with no `NN_` prefix
(`.opencode/skills/plan-management/SKILL.md`). **Nothing here is claimed landed.**

**This plan is the CANONICAL OWNER of the arrival contract.** The rider plan
`rider_app_plans/01_[arrival]_auto_arrival_nearby.md` and the driver plan
`driver_app_plans/01_[arrival]_auto_arrival_no_button.md` adopt the event shapes, field names,
JSON tags and semantics in §2 **VERBATIM**. If this plan changes a shape, both app plans must be
re-synced before either lands; the app planners do not re-derive the contract.

**Product request (verbatim):** instead of the driver clicking "Arrived at pickup", the driver
position update is checked for distance to pickup, and the rider is notified when the driver is
nearby and when the driver arrives. Trip state on both apps advances automatically.

**No migration.** The arrival transition reuses the existing `rides.status` write and the
`ride_events` table, whose `actor` column already admits `'system'`
(`internal/database/migrations/005_create_rides.up.sql:50`:
`actor TEXT NOT NULL CHECK (actor IN ('rider','driver','system'))`). Nearby state is
process-local (§3 D9).

---

## 1. Verified current state (evidence, not prose)

| Fact | Evidence |
| --- | --- |
| The single-fix hot path already resolves the caller's active ride and streams `driver.location` to the rider, but never measures distance or changes state. | `internal/handler/geo.go:62-90` (`FindCurrentRideByDriver`, `wsHub.SendToUser(... "driver.location" ...)`) |
| The batch path does **not** resolve the ride and streams nothing. | `internal/handler/geo.go:106-125` |
| Manual arrival is `PUT /api/v1/driver/rides/:id/status {status:"driver_arrived"}`. | route `internal/router/router.go:232`; handler `internal/handler/ride.go:579-595`; service `internal/service/ride.go:393-547` |
| `POST /api/v1/driver/rides/:id/notify-arrival` only notifies; it never transitions and is already unused by the driver app. | route `internal/router/router.go:235`; handler `internal/handler/platform.go:643-692`; endpoint constant defined but no call site `driver_app/lib/core/api/endpoints.dart:38` |
| State machine `pending→accepted→driver_arrived→in_progress→completed`; `accepted→driver_arrived` is a valid edge only. | `internal/service/ride.go:88-95`; `UpdateRideStatus` writes `driver_arrived_at` `internal/repository/ride_repo.go:299-314` |
| `AdvanceStatus` already broadcasts `ride.updated` to **both** rider and driver and fires `notifyOffline` for both, using `pushMessageForStatus`. | `internal/service/ride.go:420-544`; `pushMessageForStatus` "Driver arrived" `:60-86` |
| `notifyOffline` suppresses the push when the recipient has a live socket. | `internal/service/ride.go:47-55`; `Hub.IsConnected` `internal/websocket/hub.go:120` |
| `DriverLocationData` carries no proximity fields today. | `internal/websocket/messages.go:76-83` |
| `RideUpdateData` carries `ride_id`/`status`/`timestamp`. | `internal/websocket/messages.go:10-27` |
| `FindCurrentRideByDriver` returns only `accepted`/`driver_arrived`/`in_progress` for that driver, so ownership is enforced by the query. | `internal/repository/ride_repo.go:255-265`; mock `tests/testutil/mock_repos.go:519-540` |
| An O(1) haversine seam already exists in the service package. | `internal/service/ride_tracking.go:108-118` (`HaversineMeters`); the routing package has its own `internal/routing/routing.go:362-380` |
| The routing engine is used for a driver→pickup ETA at accept, not for the hot path. | `internal/service/dispatch.go:316-318` (`navSvc.GetRoute`) |
| Config is env-driven with `getFloat`/`getInt`/fail-closed bool helpers. | `internal/config/config.go:227-248,257-314` (`defaultRoutingSnapRadiusM` `:130`; `routingElevationEnabledFromEnv` `:296-305`) |
| `GeoHandler` is constructed with `(geoRepo, rideRepo, wsHub)` — it has no service seam today. | `internal/handler/geo.go:15-23`; wiring `internal/router/router.go:158` |

**Drift found while verifying (reported, not fixed here):**

- The task brief names `internal/service/ride_test.go` as a test to keep green; **that file does
  not exist**. Service tests are per-feature (`ride_push_test.go`, `ride_tracking_test.go`,
  `ride_completion_fare_test.go`). The equivalent "keep green" targets are those files.
- `driver_app_plans/STATUS.md:178` cites `router.go:159` / `platform.go:472-474` for
  `notify-arrival`; the real locations are `router.go:235` / `platform.go:643`.
- `RIDER_API_GUIDE.md:182`, `docs/swagger.{json,yaml}` and `DRIVER_APP_PLAN.md` still document
  `notify-arrival`; if §3 D5 removes the route they must be regenerated/updated in lockstep.
- The task's guardrail text says "`golangci-lint` is not installed"; `AGENTS.md` fact 2 says it
  **is** (`~/go/bin/golangci-lint`, `make lint` works). The truth is `AGENTS.md` fact 2 (the
  binary exists but is not on `PATH` by default — see `STATUS.md` → Verification). Use `make lint`.
- `AGENTS.md` "Routing endpoint contract" still says "No route → 500" before describing the
  200 `is_estimate` path; the code answers **200 `is_estimate`** for an uncovered pin
  (`internal/service/navigation.go` estimate path; `STATUS.md` bug #2 closed). Stale sentence.
- `AGENTS.md`'s stale "`pgr_dijkstra` is not wired" claim is **already corrected** (fact 3 states
  it is wired; `internal/repository/pgrouting_repo.go`). No action.

---

## 2. Canonical contract (apps adopt verbatim)

### 2.1 Trigger

On every **successful** `PUT /api/v1/geo/driver/location` (and `.../batch`) fix, for the caller's
active ride **in status `accepted`** only:

1. Resolve the ride with the existing `FindCurrentRideByDriver(driverID)`.
2. Compute `d = straight-line metres(fix → ride.pickup)`.
3. Evaluate the **arrive gate** and the **nearby crossing** (§2.3/§2.4).
4. Emit one `driver.location` event carrying the proximity fields.

No evaluation happens when the position write failed, when the caller has no active ride, or when
the ride is not `accepted`.

### 2.2 Config (all env knobs, documented defaults)

New `Config.Arrival` struct in `internal/config/config.go`, loaded in `Load()`, mirroring the
`RoutingElevation` shape and the fail-closed bool parser:

```go
// internal/config/config.go
type ArrivalGeofence struct {
    Enabled       bool    // GEOFENCE_ENABLED=on|off; unset/"" = on, garbage = off (fail-closed)
    NearbyRadiusM float64 // GEOFENCE_NEARBY_RADIUS_M; default 300
    ArriveRadiusM float64 // GEOFENCE_ARRIVE_RADIUS_M; default 80
    HysteresisM   float64 // GEOFENCE_HYSTERESIS_M;   default 30
    MinMoveM      float64 // GEOFENCE_MIN_MOVE_M;     default 10
}

const (
    defaultGeofenceNearbyRadiusM = 300
    defaultGeofenceArriveRadiusM = 80
    defaultGeofenceHysteresisM   = 30
    defaultGeofenceMinMoveM      = 10
)
```

| Env | Default | Meaning |
| --- | --- | --- |
| `GEOFENCE_ENABLED` | **on** | Master switch; unset/empty = on, anything else = off (fail-closed, same rule as `ROUTING_ELEVATION`). Off = legacy shape + no auto-advance. |
| `GEOFENCE_NEARBY_RADIUS_M` | **300** | `d ≤` this = "nearby". |
| `GEOFENCE_ARRIVE_RADIUS_M` | **80** | `d ≤` this = arrival gate (state advance). |
| `GEOFENCE_HYSTERESIS_M` | **30** | Re-arm only once `d > NEARBY + HYSTERESIS` (=330 m). |
| `GEOFENCE_MIN_MOVE_M` | **10** | Movement below this suppresses nearby-crossing bookkeeping (never the arrive gate, §3 D3). |

A non-positive radius disables that leg (fail-closed: never fires). `ARRIVE` must be `≤ NEARBY`;
if misconfigured (`ARRIVE > NEARBY`) the evaluator clamps `ARRIVE = NEARBY` and logs once.

### 2.3 Arrival — state advance (server-authoritative)

Condition: `ride.status == "accepted"` **and** `d ≤ GEOFENCE_ARRIVE_RADIUS_M` **and** the caller is
the ride's `driver_id`.

Effect (reuse the existing transition, do **not** hand-roll a second broadcaster):

1. Transition via the existing state machine with actor **`"system"`**
   (`AdvanceStatus(rideID, "driver_arrived", "system")` or the guarded variant of §3 D10).
2. Persist `rides.status='driver_arrived'` + `driver_arrived_at`
   (`internal/repository/ride_repo.go:299-314`).
3. Write a `ride_events` row `from='accepted' to='driver_arrived' actor='system'`.
4. Broadcast `ride.updated` to **BOTH** rider and driver:
   ```json
   {"type":"ride.updated","data":{"ride_id":"<id>","status":"driver_arrived","timestamp":"<RFC3339>"}}
   ```
5. `notifyOffline(rider, pushMessageForStatus("driver_arrived", rideID))` — and, because
   `AdvanceStatus` already does it, the driver too.

**Idempotent:** once the row is `driver_arrived` (or `in_progress`/terminal) the geofence is
skipped because the status is no longer `accepted`; the state machine also rejects
`driver_arrived→driver_arrived`. A ride is never re-advanced, never re-notified.

**A failed transition never fails the location update:** log the cause and still answer `204`.

### 2.4 Nearby — notification only, no state change

Additive fields on the existing `driver.location` event (`internal/websocket/messages.go`):

```go
type DriverLocationData struct {
    RideID   string  `json:"ride_id"`
    DriverID string  `json:"driver_id"`
    Lat      float64 `json:"lat"`
    Lng      float64 `json:"lng"`
    Heading  float64 `json:"heading"`
    Speed    float64 `json:"speed"`

    // Additive proximity fields (api_plans/[arrival]_proximity_arrival_geofence.md).
    // Present only while the caller's active ride is status "accepted"; the
    // legacy shape is unchanged otherwise (omitempty).
    NearPickup        bool    `json:"near_pickup,omitempty"`
    DistanceToPickupM float64 `json:"distance_to_pickup_m,omitempty"`
}
```

Semantics:

- `distance_to_pickup_m` = **straight-line (haversine) metres** from the fix to the ride's pickup;
  present while `accepted` (omitted when `0`).
- `near_pickup` = `true` once the fix has crossed into `d ≤ NEARBY_RADIUS_M`; stays `true` until
  `d > NEARBY_RADIUS_M + HYSTERESIS_M`, then clears (re-arms). Omitted while `false`.
- Fields are **omitted** (legacy payload) when there is no `accepted` active ride for the caller.
- The live `driver.location` event is the foreground nearby signal; the push below is only for a
  backgrounded rider.
- **Nearby never changes `ride.status`.** It must never carry a status the DB does not hold.

**Backgrounded nearby push** (canonical payload; fired once per crossing via `notifyOffline`):

```go
push.Message{
    Title: "Driver nearby",
    Body:  "Your driver is almost at the pickup point.",
    Data: map[string]string{
        "type":        "ride.nearby",
        "status":      "accepted",
        "ride_id":     rideID,
        "near_pickup": "true",
    },
}
```

The arrival push keeps the existing shape from `pushMessageForStatus("driver_arrived", rideID)`:
`data = {"type":"ride.updated","status":"driver_arrived","ride_id":<id>}`.

### 2.5 Honesty invariants (hard)

- **Never advance or notify on a failed/unknown position or a failed `FindCurrentRideByDriver`.**
  `ErrNotFound` (no active ride) is benign and silent; any other repo error is logged and skips the
  geofence for that fix. A down ride repo must never fabricate an arrival.
- **Never emit `driver_arrived` without crossing the arrive gate.** The only auto path to
  `driver_arrived` is `d ≤ ARRIVE`; the manual `PUT /:id/status` stays as an explicit human
  override (§3 D5/D6).
- **Never advance a ride whose `driver_id` ≠ caller.** `FindCurrentRideByDriver(driverID)` already
  guarantees it; the evaluator re-checks defensively.
- **Nearby must not lie about status.** `near_pickup` is an advisory signal; `status` stays
  `accepted` until the arrive gate.
- The location endpoint stays `204` on success and `422`/`500` on the existing validation/write
  failures — the geofence changes **no** status code.
- Ancillary pushes stay fire-and-forget and must never delay or fail the `204`.

---

## 3. Decisions surfaced (options → tradeoffs → recommendation)

### D1 — Who advances the state? **API (fixed).**
Server-authoritative, because a client cannot be trusted to time an arrival and the rider must see
one truth. Both apps only render the broadcast. No option to debate.

### D2 — Distance function: **haversine on the hot path [RECOMMENDED]** vs `navSvc.GetRoute`.

- **Haversine (`service.HaversineMeters`, `internal/service/ride_tracking.go:111`)** — O(1),
  allocation-light, DB-free, no region resolution. At 80–300 m thresholds the road-vs-straight-line
  difference is far below GPS noise (~5–10 m) and the arrival decision is "is the car basically
  here", not "how far by road". A straight-line gate also **cannot be disabled by a routing
  outage/no-coverage**.
- **`navSvc.GetRoute`** — a graph search plus region resolution per fix. The measured real-graph
  hot path is ~84–112 ms/op (`STATUS.md` → `[elevation]` flip: 83.9 ms flat, 112.3 ms elevated);
  a driver fix can arrive every 1–5 s. It can also answer `is_estimate`/`ErrPinUncovered` and, for
  `pgrouting`, hit a remote datasource — coupling the geofence to routing availability and adding a
  network round trip to a per-second endpoint.

**Recommendation: haversine.** The field name is `distance_to_pickup_m` (not "road distance"),
so the contract is honest about being straight-line. If a future stage wants a road ETA, it is a
separate additive field, not this gate.

### D3 — Thresholds + hysteresis + debounce: **300 / 80 / 30 / 10 [RECOMMENDED].**
300 m is a comfortable "almost here" radius at urban speeds; 80 m is roughly one vehicle length
plus GPS error, so arrival fires when the driver is at the kerb without a false positive from a
passing parallel street. 30 m hysteresis stops the `near_pickup` flag flickering at the 300 m
boundary. **Critical nuance:** `GEOFENCE_MIN_MOVE_M` gates only the *nearby-crossing bookkeeping /
push*, **never the arrive gate** — a slow creep from 82 m to 77 m in 5 m steps must still fire
arrival. Document that in the code comment. All four are env-tunable; no measured-sweep gate is
required because they are product UX thresholds, not a cost model.

### D4 — Nearby delivery: **additive `driver.location` fields + push-when-backgrounded
[RECOMMENDED]** vs new `ride.updated` vs push-only.

- **Additive `driver.location` fields + backgrounded push** — the foreground path already streams
  `driver.location` on every fix, so this is pure addition; `status` cannot lie; the push covers a
  backgrounded rider.
- **New `ride.updated`** — **rejected:** a `ride.updated` implies a status transition; emitting one
  while the DB still holds `accepted` is exactly the lie `[dispatch]`'s "a push must never announce
  a status the database does not hold" invariant forbids.
- **Push-only** — works but a foreground rider sees nothing until arrival, and it burns a push for
  every connected rider. Rejected.

### D5 — Manual path fate: **keep `PUT /:id/status`; remove `POST /:id/notify-arrival` [RECOMMENDED].**
- `PUT /api/v1/driver/rides/:id/status` stays as the recovery/testing seam (and the D6 optional
  "Report arrived" secondary). The driver app's primary "Arrived at pickup" button is removed by
  `driver_app_plans/01_[arrival]_auto_arrival_no_button.md`.
- `POST /:id/notify-arrival` is **redundant** (notify-only, no transition), already unused by the
  driver app (`endpoints.dart:38` has no call site), and duplicates the new arrival push. Remove the
  route (`router.go:235`) and handler (`ArrivalNotification`), no alias — the precedent is the
  `/estimates/price` GET→POST hard cutover (`STATUS.md` → Landed `[fare]`). In lockstep:
  regenerate `docs/swagger.{json,yaml}`, update `RIDER_API_GUIDE.md:182`, and delete/repurpose
  `tests/notify_arrival_test.go` (move its push-honesty assertions into the new
  `tests/arrival_geofence_test.go`). If a staged rollout is preferred, keep it as a no-op 200
  deprecation instead — but then it must not push a status the DB does not hold.

### D6 — Driver manual override: **none by default [RECOMMENDED]**; optional secondary.
Default none: the whole point is auto-advance. Offer an optional **"Report arrived"** secondary
control (same `PUT /:id/status {driver_arrived}`) for the GPS-denied / wrong-parking case; it is a
driver-plan decision and the API needs no change either way.

### D7 — Batch path: **evaluate the geofence on the FINAL fix only [RECOMMENDED].**
The batch loop upserts every fix; after the loop, resolve the ride **once** and run the same
geofence evaluation + emit **one** `driver.location` for the final fix. Intermediate fixes remain
position-only (unchanged). This closes the current drift that the batch path never resolves the
ride. One evaluation, one possible transition.

### D8 — Tag: **`[arrival]` [RECOMMENDED]** over `[geo]`.
`[geo]` is the existing surface for positions/nearby-drivers and is too broad; `[arrival]` is the
distinct capability slice (proximity geofence + auto state advance + nearby notify) that spans
config/service/handler/websocket and must be traceable across the three domains.

### D9 — Nearby-state storage: **process-local in-memory map in `RideService` [RECOMMENDED for this stage]**
vs a `rides` column (migration).

- **In-memory `map[rideID]nearState{lastLat,lastLng,nearFired}`**, mutex-guarded, owned by
  `RideService`. Zero DB writes on the hot path. Entries are deleted when the ride leaves
  `accepted`. Caveats to document in the code: a server restart re-arms `near_pickup` (a rider may
  get one duplicate nearby push while still en route), and with **multiple pods** each pod may push
  once.
- **A `rides` column** (e.g. `near_pickup_notified_at`) would make the dedup durable and
  multi-pod-correct, at the cost of a migration + a DB write per crossing. Recommended only if the
  product commits to multi-pod for this feature.

**Recommendation: in-memory for stage 1** (single-pod dev harness, arrival is DB-idempotent via the
state machine, nearby duplicates are harmless UX). The migration option is the natural `01_`
follow-up (see D10).

### D10 — Multi-pod arrival idempotency: **harden with a conditional UPDATE [RECOMMENDED]**, or
accept single-pod.

`UpdateRideStatus` is an unconditional `UPDATE rides SET status=$2 ... WHERE id=$1`
(`internal/repository/ride_repo.go:299`). Under a true multi-pod race, two pods can both read
`accepted` and both write `driver_arrived`, double-inserting a `ride_events` row and double-
broadcasting. The single-pod read-then-write is logically idempotent but not race-safe.

**Recommended hardening (no migration):** add
`RideRepository.UpdateRideStatusFrom(rideID, fromStatus, status string, ts *time.Time) (bool, error)`
(`UPDATE ... WHERE id=$1 AND status=$2`, `RowsAffected()==1`), have the geofence transition use it
and skip the event/broadcast when it reports `false`, and keep `AdvanceStatus` delegating with an
empty guard for the manual path. Mock moves in lockstep (`tests/testutil/mock_repos.go`). If the
product accepts the documented single-pod assumption instead, this becomes
`01_[arrival]_multi_pod_arrival_idempotency.md` (numbered because its `depends_on` names **this
open plan**) — not opened now.

### D11 — Kill switch: **add `GEOFENCE_ENABLED` (default on) [RECOMMENDED].**
Mirrors `ROUTING_ELEVATION`'s fail-closed parse; the only safe rollback that does not require a
code redeploy. Off = legacy `driver.location` shape and no auto-advance.

---

## 4. Implementation seam (files to touch; code, not yet written)

1. **`internal/config/config.go`** — `ArrivalGeofence` struct + defaults + `Load()` wiring +
   `geofenceEnabledFromEnv()` (fail-closed, `os.Getenv` not `getEnv`, same as
   `routingElevationEnabledFromEnv`).
2. **`internal/websocket/messages.go`** — two additive fields on `DriverLocationData` (§2.4).
3. **`internal/service/arrival.go`** (new) — `EvaluateArrival` on `RideService`, the in-memory
   `nearState` map, `SetArrivalGeofence(cfg)`, and the nearby push builder. Signature (canonical
   seam):
   ```go
   // EvaluateArrival observes one accepted-phase fix for the caller's ride. It may
   // advance the ride to driver_arrived (server-authoritative) and fire the
   // backgrounded nearby push on the first crossing. It never returns an error: a
   // geofence failure must not fail the location update. It returns the proximity
   // fields for the driver.location event.
   func (s *RideService) EvaluateArrival(ride *model.Ride, driverID string, lat, lng float64) (nearPickup bool, distanceToPickupM float64)
   ```
4. **`internal/handler/geo.go`** — a narrow `ArrivalEvaluator` interface + a 4th `NewGeoHandler`
   param; call it on the single path and once on the batch's final fix; fill the event fields.
   ```go
   type ArrivalEvaluator interface {
       EvaluateArrival(ride *model.Ride, driverID string, lat, lng float64) (nearPickup bool, distanceToPickupM float64)
   }
   func NewGeoHandler(geoRepo repository.GeoRepository, rideRepo repository.RideRepository, wsHub *websocket.Hub, arrival ArrivalEvaluator) *GeoHandler
   ```
5. **`internal/router/router.go`** — `rideService.SetArrivalGeofence(cfg.Arrival)` after
   `SetPushNotifier`; pass `rideService` to `NewGeoHandler` (`:158`). `SetupWithRepos` builds the
   real `RideService`, so `tests/testutil` gets the wiring for free.
6. **D5/D10 only if taken** — remove the `notify-arrival` route/handler; add
   `UpdateRideStatusFrom`.

No migration. No `NavigationRepository` change. No route-cost change.

---

## 5. Tests to add / change

| File | Cases |
| --- | --- |
| `internal/service/arrival_test.go` (new) | arrive gate fires `driver_arrived` with actor `system` and one event; idempotent when already `driver_arrived`/`in_progress`/terminal; no advance when `status != accepted` or `driver_id != caller`; nearby first crossing sets `near_pickup`, clears past `NEARBY+HYSTERESIS`, re-arms; `MIN_MOVE` suppresses nearby bookkeeping but **never** the arrive gate; `ARRIVE > NEARBY` clamps; push shape `ride.nearby`; a transition failure is logged and swallowed |
| `internal/handler/geo_arrival_test.go` (new) | `accepted` + fix ≤80 m → 204, status transitioned, event fields present; fix in 80–300 m → `near_pickup:true`, no transition; fix >300 m → distance present, near absent; no active ride → legacy payload, 204; failed `FindCurrentRideByDriver` (via `FailNext`) → 204, no transition; batch final-fix evaluates once (and intermediate fixes do not) |
| `internal/config/config_test.go` | defaults 300/80/30/10; `GEOFENCE_ENABLED` unset/empty=on, garbage=off; invalid float falls back to default; `ARRIVE > NEARBY` clamp at the consumer |
| `tests/arrival_geofence_test.go` (new, mock server via `testutil.NewTestServerE`) | end-to-end: seed an `accepted` ride, connect rider+driver WS, PUT a fix ≤80 m → both receive `ride.updated {status:"driver_arrived"}` and `ride.status` is persisted; backgrounded rider gets exactly one arrival push (reuse the spy-provider pattern from `tests/notify_arrival_test.go`); nearby crossing emits `driver.location.near_pickup` and one `ride.nearby` push; batch-path case |
| `tests/notify_arrival_test.go` | **delete** (D5) and move the "connected rider gets WS, no push" / "backgrounded gets exactly one push" assertions into `tests/arrival_geofence_test.go` |
| keep green | `internal/service/ride_push_test.go`, `ride_tracking_test.go`, `ride_completion_fare_test.go`, `internal/handler/ride_test.go`, `tests/geo_test.go`, `tests/ride_lifecycle_test.go` |

Mocks in lockstep: any new repo method (D10) must be added to `tests/testutil/mock_repos.go` with
the same failure reachability rule (`STATUS.md` → Invariants).

---

## 6. Verification

```bash
make test                      # unit, no DB — must stay green
make lint                      # golangci-lint v2 (binary at ~/go/bin/golangci-lint); 0 issues
gofmt -w <touched-files> && go vet ./...
make test-integration          # DB-backed
```

On-host closing steps (the harness has no device/GPS):

- `curl -sS -X PUT .../geo/driver/location` for an `accepted` ride at 250 m (expect a
  `driver.location` with `near_pickup:true` and a `ride.nearby` push in the log) then at 60 m
  (expect `ride.updated {driver_arrived}` and `rides.status='driver_arrived'`), then repeat at 60 m
  (expect **no** second transition/push).
- `docker compose`-less path: `make run` and watch the `[push]` `LogProvider` lines.

**Android / on-device GPS cadence is UNVERIFIABLE here.** The driver app's publish interval and
background behaviour are owned by `driver_app_plans`; this plan only fixes the server contract.

---

## 7. Open inputs / unknowns

| # | Unknown | Resolution |
| --- | --- | --- |
| 1 | Final product thresholds (300/80/30) | Confirm with the product owner; all are env-tunable, so this is a value, not a code change |
| 2 | `GEOFENCE_MIN_MOVE_M` default (10 recommended) | Confirm against the driver app's publish cadence (`driver_app_plans`) |
| 3 | Multi-pod required? (D10) | If yes, take the conditional-UPDATE hardening now; if no, document single-pod and open `01_[arrival]_multi_pod_arrival_idempotency.md` |
| 4 | Remove vs deprecate `notify-arrival` (D5) | Confirm lockstep timing with `driver-planner`; if staged, deprecate to a no-op |
| 5 | Optional "Report arrived" secondary (D6) | `driver-planner` decision; no API change |
| 6 | `distance_to_pickup_m` for `driver_arrived`/`in_progress` | This plan scopes proximity fields to `accepted`; extend additively later if the apps want a live distance after arrival |

---

## 8. Dangling-`depends_on` check

`depends_on` names **landed** capability only (`"landed geo driver-location hot path + [tracking]
actuals (STATUS.md)"`), so the file is correctly **unnumbered**. No open plan is referenced, so
there is no dangling dependency. No `01_` follow-up is opened; D10 is the only candidate and is
documented, not created. The sibling open `[routing]_nationwide_costa_rica.md` is untouched and
independent.

---

## 9. Cross-domain adoption (do not re-plan in this file)

- `rider_app_plans/01_[arrival]_auto_arrival_nearby.md` — consumes `driver.location.near_pickup` /
  `distance_to_pickup_m`, the `ride.updated {driver_arrived}` broadcast and the `ride.nearby` push;
  adopts §2 verbatim.
- `driver_app_plans/01_[arrival]_auto_arrival_no_button.md` — removes the manual arrival button
  (driver app already advances via `PUT /:id/status`, `trip_notifier.dart:167-189`); adopts §2
  verbatim and stops relying on the removed `notify-arrival`.

Both plans `depends_on` this plan (open), so they carry the `01_` prefix in their own domains; this
file remains the canonical contract owner.
