---
tag: arrival
depends_on: ["[rides]_cancel_accept_race.md"]
status: open
---

# Plan: evaluate proximity arrival once at accept time

**Stage `01` of the `[arrival]` chain.** Beyond its landed prerequisites (the `[arrival]`
proximity geofence and the `[dispatch]` accept loop), this plan depends on the **open** chain head
`[rides]_cancel_accept_race.md`: that plan is the canonical owner of the atomic conditional status
write and of `ErrTransitionConflict`. This plan does **not** implement or rename those symbols; it
adopts them verbatim (§2.1, §5).

**Sequencing is hard:** stage `01` **cannot land before** `[rides]_cancel_accept_race.md` lands.
The CAS behavior and its cross-transition regression table belong to that plan (§1.1–§1.3, §5.1
there), not here. This plan only adds accept-time evaluation and the scenario test that proves it
cannot duplicate a `driver_arrived` event against the rides plan's CAS.

This plan is **open**: nothing below is implemented yet.

**App-side context (already fixed, uncommitted — keep it).** A driver who accepts an offer while
already at (or inside the 80 m arrive radius of) the pickup gets no new geolocator fix: the
stream uses `distanceFilter: 10`. `PUT /geo/driver/location` is therefore never sent, the
server-side geofence never evaluates, and the ride stays `accepted`. The driver app re-publishes
its cached fix on trip mount and on the accepted `ride.updated` confirmation —
`driver_app/lib/features/trip/presentation/trip_screen.dart:39,52-58,196-201`, tests
`driver_app/test/features/trip/presentation/trip_screen_test.dart:288-313`. That client fix stays
as defence in depth. **This plan is API hardening:** the server evaluates arrival once at accept
time from the last `driver_positions` fix, so arrival no longer depends on the client pushing a
fix after accept.

---

## 1. Problem and exact accept-time sequence

Today the only thing that advances `accepted → driver_arrived` is the geo hot path —
`RideService.EvaluateArrival` (`internal/service/arrival.go:58-91`) called from
`internal/handler/geo.go:50-59,91,173`. If no fix arrives after accept, nothing fires.

`DispatchService.AcceptRide` (`internal/service/dispatch.go:400`) runs, in order:

1. `rideRepo.FindByID` — the returned object is still `pending` (`dispatch.go:401-405`).
2. Status guard `ride.Status != "pending"` (`dispatch.go:407-409`).
3. `rideRepo.AssignDriver` (`dispatch.go:410`) → `internal/repository/ride_repo.go:411-427`
   sets `driver_id`, `status='accepted'`, `accepted_at=NOW()`, `updated_at=NOW()`, guarded on
   `WHERE id=$2 AND status='pending'`, so the accept write itself is race-safe.
4. `CreateEvent` `pending → accepted` (best-effort, `dispatch.go:412-420`).
5. `FindDriverByID`, then the last fix for the rider ETA:
   `GetDriverLocation` at `dispatch.go:442`, inside `if driver != nil` (`dispatch.go:430-465`).
6. Build and send `ride.updated status=accepted` to the rider and driver —
   `dispatch.go:466-480` (sends at `:479-480`).
7. `return nil`.

The in-memory `ride` from step 1 still says `pending` and has a nil `driver_id`. Any
accept-time evaluation therefore needs a **local status/driver update or a re-read** before
calling the evaluator (`EvaluateArrival` requires `ride.Status == "accepted"`,
`internal/service/arrival.go:73-77`, and a matching `ride.DriverID`,
`internal/service/arrival.go:66-71`).

**The accept path is not just the HTTP handler.** The driver app accepts primarily over the
WebSocket (`driver_app/lib/features/rides/presentation/offer_sheet.dart:135-140`): the frame
`ride.accept` is handled at `internal/websocket/hub.go:184-191` → `HandleAccept`
(`internal/service/dispatch.go:364-372`) → the dispatch goroutine's offer wait
(`internal/service/dispatch.go:344-355`) → `acceptOfferedRide`
(`internal/service/dispatch.go:296-307`) → `AcceptRide`. The HTTP endpoint
(`internal/handler/ride.go:681-696`, route `internal/router/router.go:253`) is the **fallback**
(`driver_app/lib/features/rides/presentation/offer_sheet.dart:144-148`). Both converge in
`DispatchService.AcceptRide`.

---

## 2. Where the evaluation runs (recommendation + trade-off)

**Recommendation: inside `DispatchService.AcceptRide`**, via a narrow evaluator seam implemented
by `*service.RideService`; the exact ordering relative to the accepted broadcast is D3 (§4).

> **Dependency naming:** after `[rides]_cancel_accept_race.md` lands, this function is renamed
> `acceptRide` (unexported) and both the WS and HTTP paths converge through
> `DispatchService.HandleAccept` (rides plan §4.1). The call site stays the same single accept
> write; read `AcceptRide` below as "the one accept write" (today `internal/service/dispatch.go:400`,
> post-dependency `acceptRide`).

| Option | Covers WS accept | Covers HTTP accept | Notes |
| --- | --- | --- | --- |
| Handler-level after `dispatchService.AcceptRide` | **No** | Yes | `RideHandler` does hold both services (`internal/handler/ride.go:18-34`), but the primary WS path never reaches the handler. Also needs a new fix-fetch seam because the handler owns no `GeoRepository`. |
| `DispatchService.AcceptRide` evaluates internally | **Yes** | **Yes** | One convergence point; reuses the fix already fetched for the ETA; no handler DTO change. |
| `AcceptRide` returns extra fix/age metadata, e.g. `(*model.Ride, float64, error)` | **Yes** | **Yes** | Changes a public signature and pushes orchestration into callers; the WS caller (`dispatch.go:297`) is a goroutine with no HTTP response to decorate. (The rejected `DriverFix` return shape was removed by D6.) |
| Callback/observer registered on the dispatch service | **Yes** | **Yes** | Same as option 2, slightly more indirection; useful only if the evaluator must be optional in tests. |

Pick the second option with an optional setter (so db-less tests and legacy wiring compile
unchanged).

### 2.1 Canonical symbols (one block — D2/D4/D6; CAS adopted, not defined here)

```go
// internal/model/geo.go — D6=B: no model.DriverFix; NearbyDriverResult gains the
// SQL-computed freshness the accept path needs.
type NearbyDriverResult struct {
    DriverID  string    `db:"driver_id" json:"driver_id"`
    Lat       float64   `json:"lat"`
    Lng       float64   `json:"lng"`
    Heading   float64   `db:"heading" json:"heading"`
    Speed     float64   `db:"speed" json:"speed"`
    DistanceM float64   `db:"distance_m" json:"distance_m"`
    UpdatedAt time.Time `db:"updated_at" json:"-"`   // D6=B, selected by GetDriverLocation
    AgeS      float64   `db:"age_s" json:"-"`        // D2=A, EXTRACT(EPOCH ...)::double precision
}

// internal/repository/geo_repo.go — extend the existing read; NO new
// GetDriverLocationWithAge method.
GetDriverLocation(driverID string) (*model.NearbyDriverResult, error)
// SELECT driver_id, ST_X(location::GEOMETRY) AS lng, ST_Y(location::GEOMETRY) AS lat,
//        heading, speed, updated_at,
//        EXTRACT(EPOCH FROM (NOW() - updated_at))::double precision AS age_s
// FROM driver_positions WHERE driver_id = $1

// internal/service/arrival.go — D4=A: arrive-only entry point.
func (s *RideService) EvaluateArrivalAtAccept(ride *model.Ride, driverID string, lat, lng float64) bool

// internal/service/dispatch.go
type AcceptArrivalEvaluator interface {
    // EvaluateArrivalAtAccept advances accepted -> driver_arrived when the fix is
    // inside the arrive radius. It never runs the nearby branch or mutates
    // nearby hysteresis state, and it never panics or returns an error.
    EvaluateArrivalAtAccept(ride *model.Ride, driverID string, lat, lng float64) bool
}
func (s *DispatchService) SetArrivalEvaluator(e AcceptArrivalEvaluator)

// CAS — ADOPTED VERBATIM from api_plans/[rides]_cancel_accept_race.md §1.1.
// This plan must not implement, wrap, or rename it:
//   UpdateRideStatusFrom(rideID string, expectedFrom []string, status string, timestamp *time.Time) (updated bool, err error)
//   ErrTransitionConflict
// After that chain head lands, RideService.AdvanceStatus already uses
// UpdateRideStatusFrom and returns ErrTransitionConflict on updated == false;
// EvaluateArrivalAtAccept inherits that behaviour by calling AdvanceStatus.
```

`*RideService` implements the evaluator. Wire it next to the existing geofence install:
`internal/router/router.go:168` (`rideService.SetArrivalGeofence(cfg.Arrival)`) and
`internal/router/router.go:172` (`NewDispatchService`), i.e. after both services exist:
`dispatchService.SetArrivalEvaluator(rideService)`.

The evaluator must be a **separate entry point** from `EvaluateArrival`, because the accept-time
call must not run the nearby (`ride.nearby`) branch (§7): add
`EvaluateArrivalAtAccept(...) bool` to `internal/service/arrival.go` and factor the shared
arrive gate out of `EvaluateArrival` (`:81-89`).

**Ordering inside the accept write is D3 = A (§4):** send `ride.updated status=accepted`
(`dispatch.go:479-480`) first, **then** run the accept-time evaluation, so the arrival transition's
`driver_arrived` broadcast follows the accepted patch. The wire order must never be
`driver_arrived` then `accepted`.

---

## 3. Freshness decision — D1=A, D2=A

`GetDriverLocation` (`internal/repository/geo_repo.go:125-138`) selects only
`lng, lat, heading, speed` and returns `*model.NearbyDriverResult`
(`internal/model/geo.go:27-34`), which has **no timestamp**. The `driver_positions.updated_at`
column exists and is written on every upsert (`internal/repository/geo_repo.go:68-80`), so a
freshness gate needs **no migration** — only a query/model change.

**D1 = A — maximum accept-time fix age is 60 s.** Rationale (unchanged, now decided):

- Dispatch only offers to a driver whose position row is younger than
  `DriverLivenessWindow = 30s` (`internal/repository/geo_repo.go:39`; filter at `:109`).
- A delivered offer waits up to `offerTimeout = 30s` for the answer
  (`internal/service/dispatch_observability.go:215-216`; wait at `internal/service/dispatch.go:344-355`).
- Therefore the fix used at accept can be **≈ 60 s old** even in the healthy path; 60 s is the
  offer contract's worst case, not an arbitrary grace period.

**D1 sub-choice = env-tunable, shipped default 60 s.** Add `GEOFENCE_ACCEPT_FIX_MAX_AGE_S`,
mirroring the existing `GEOFENCE_*` parsing/default style (`internal/config/config.go:262-287,343-349`,
helpers at `:415-422`). Semantics are fail-closed:

- **unset/empty → 60** (the shipped default);
- a finite value **> 0 → that many seconds**;
- **garbage, non-finite, or ≤ 0 → 0**, which **skips accept-time evaluation** entirely — never
  "trust everything" — and doubles as the ops rollback without a redeploy.

`GEOFENCE_ENABLED=off` still disables the **whole** geofence (live PUT path and accept-time
evaluation); this new knob is independent and can only narrow the accept-time gate, never
re-enable a disabled geofence.

```go
// internal/config/config.go — ArrivalGeofence
AcceptFixMaxAgeS float64 // GEOFENCE_ACCEPT_FIX_MAX_AGE_S; default defaultGeofenceAcceptFixMaxAgeS (60);
                         // unset/"" = 60; garbage/non-finite/<=0 = 0 => skip accept-time evaluation
const defaultGeofenceAcceptFixMaxAgeS = 60
func geofenceAcceptFixMaxAgeFromEnv() float64 // fail-closed; mirrors payoutCommissionFromEnv's NaN/Inf handling
```

Add it to the `Arrival: ArrivalGeofence{...}` block in `config.Load` and parse tests (unset, valid,
garbage, zero, negative) next to `TestGeofenceConfigFromEnv`
(`internal/config/config_test.go:483-548`).

**D2 = A — freshness is evaluated SQL-side, never with `time.Since`/the app clock.** The age used
by the gate must be produced by Postgres in the same read as the fix. This is why the canonical
read below returns `AgeS` (seconds, `EXTRACT(EPOCH FROM (NOW() - updated_at))::double precision`) as well as
`UpdatedAt`; the gate reads `AgeS` only. Comparing an app-side `time.Now()` to `UpdatedAt` is
**rejected** even though it is simpler: it is wrong across an app/DB clock split and would make
the 60 s contract unverifiable from the DB row.

**Contract (D6 = B — no `model.DriverFix`; no new read method).** Keep `GetDriverLocation`'s
signature and extend what it selects/returns:

- `internal/model/geo.go` → add `UpdatedAt time.Time `db:"updated_at" json:"-"`` **and**
  `AgeS float64 `db:"age_s" json:"-"`` to `NearbyDriverResult` (`:27-34`). Both are internal:
  `GET /drivers/:id/location` marshals this struct directly (`internal/handler/geo.go:265-272`),
  so `json:"-"` keeps that response shape unchanged.
- `internal/repository/geo_repo.go:125-138` → select `updated_at` and
  `EXTRACT(EPOCH FROM (NOW() - updated_at))::double precision AS age_s`.
- `FindNearbyDrivers` (`:97-121`) is untouched: it selects no `updated_at`/`age_s`, so the new
  fields stay their zero values there and no existing consumer changes.
- **Rejected:** a separate `GetDriverLocationWithAge(*model.DriverFix)` read. It duplicates the
  query and the model for one timestamp and would leave the existing call site
  (`internal/service/dispatch.go:442`) on a second, freshness-blind read.

This is the smallest shape that satisfies D2 and D6 together: one query, two additive struct
fields (`UpdatedAt` for the contract/D6, `AgeS` for the D2 age).

**Risks to state explicitly:**

- **False arrival (gate too loose):** an old fix within 80 m of the pickup while the driver has
  since moved marks `driver_arrived` at accept. The rider sees "driver has arrived" while the
  driver is elsewhere; the driver's next real fix cannot undo the status (the state machine only
  moves forward, `internal/service/ride.go:119-126`). The 60 s bound is the mitigation.
- **Missed arrival (gate too tight):** the fix is inside 80 m but older than 60 s, so accept-time
  evaluation does nothing. The app-side re-publish remains the only path, so this hardening
  silently no-ops in exactly that case.

**Where the gate lives:** `DispatchService.AcceptRide`, because that is where the fix is already
fetched for the ETA (`dispatch.go:442`) and where both accept paths converge. The evaluator itself
must stay freshness-agnostic (it is also called from the live PUT path, which is inherently fresh).

---

## 4. Event ordering — D3 = A (keep both WS patches)

When accept-time arrival fires immediately after accept, clients receive, in this order:

```
ride.updated status=accepted       (AcceptRide, dispatch.go:467-480; carries Driver/Pickup/
                                    Dropoff/EtaSeconds, Driver nil only if FindDriverByID failed)
ride.updated status=driver_arrived (AdvanceStatus, ride.go:450-459; RideID/Status/Timestamp only —
                                    no Driver/Pickup/Dropoff/EtaSeconds)
```

The accept-time evaluation runs **after** the accepted sends at `dispatch.go:479-480`, so the two
patches are broadcast by the same goroutine in that order. **Zero client change.**

Verified payload shape: `websocket.RideUpdateData` has `Driver`, `Pickup`, `Dropoff`,
`EtaSeconds` behind `omitempty` (`internal/websocket/messages.go:10-27`); `AcceptRide` populates
them (`dispatch.go:467-477`), while `AdvanceStatus` builds only `RideID`/`Status`/`Timestamp`
(`internal/service/ride.go:450-459`) and adds fare/actuals only in the completion block
(`ride.go:590-600`). So the arrival patch carries **no driver information**.

Verified client effects of A:

- Driver: `TripNotifier._stageFromStatus` maps `accepted → enrouteToPickup` and
  `driver_arrived → arrived` (`driver_app/lib/features/trip/providers/trip_notifier.dart:182-187`;
  the enum comment at `:14-17` deliberately keeps them distinct). `advance()` sends nothing from
  `enrouteToPickup` (`:326-337`), so the brief accepted stage cannot fire a wrong transition.
- Rider: `_statusFromBackend` maps `accepted → driverApproaching` and
  `driver_arrived → driverArrived`
  (`rider_app/lib/features/home/data/ride_status_provider.dart:226-229`). The rider sees a brief
  "driver approaching" flash and then "driver arrived"; the driver's identity/ETA survive the
  arrival patch because `_handleRideUpdated` keeps the previous `driver` when the patch omits it
  and `copyWith` keeps a nil `driverId`/`etaSeconds` (`ride_status_provider.dart:131-145`,
  `:58-78`).
- Offline: `AcceptRide` sends **no offline push** (the whole function at `dispatch.go:400-482`
  calls only `hub.SendToUser`; there is no `notifyOffline`), whereas `AdvanceStatus` broadcasts
  and fires `notifyOffline` for `driver_arrived` to both users (`internal/service/ride.go:606-615`).
  `notifyOffline` is a no-op when the user has a live socket (`ride.go:78-87`), so a connected
  client is never double-notified by WS+push; a backgrounded rider gets exactly the one
  `driver_arrived` push.
- Client files to verify (no change expected): `trip_notifier.dart:175-190`,
  `ride_status_provider.dart:110-150`, `active_ride_screen.dart:80-100`.

**Considered and rejected:**

- **B — one merged `driver_arrived` broadcast carrying the accepted payload.** Cleanest UX (no
  accepted→arrived flash) and clients tolerate the richer payload, but it invents a special
  arrival-with-driver message shape inside/around the shared `AdvanceStatus` state machine, makes
  the driver's "accepted" confirmation depend on the arrival broadcast, and mandates carrying
  accept-only fields on every transition path. Rejected: zero-client-change A is sufficient.
- **C — suppress the accept-time arrival offline push.** Its premise ("avoid the double
  notification") is false: `AcceptRide` fires no offline push and `notifyOffline` skips live
  sockets, so there is no duplicate; suppressing the `driver_arrived` push would delete the only
  notification a backgrounded rider gets. Rejected; a silent arrival would be a separate product
  change to `AdvanceStatus`.

---

## 5. Idempotency and races — D5=A (dependency on the `[rides]` CAS, not an implementation step)

Two writers can hit `accepted → driver_arrived` at nearly the same time: the accept-time
evaluation and a client `PUT /geo/driver/location` (the app's re-published cached fix). Today the
transition is not DB-idempotent: `RideService.AdvanceStatus` (`internal/service/ride.go:433-447`)
does `FindByID` → validate against `validTransitions` (`ride.go:119-126`) → `UpdateRideStatus`
(`internal/repository/ride_repo.go:299-325`), and that UPDATE has **no `WHERE status = <from>`
predicate** (interface at `internal/repository/ride_repo.go:25`). Two goroutines that both read
`accepted` both pass validation and both write, both insert a `ride_events` row, and both
broadcast/push.

**D5 = A is a human-approved behavior, but its canonical owner is
`api_plans/[rides]_cancel_accept_race.md`.** That chain head:
- defines the one conditional write `UpdateRideStatusFrom(rideID, expectedFrom []string, status
  string, timestamp *time.Time) (updated bool, err error)` (rides plan §1.1);
- adds `ErrTransitionConflict` and maps it to `409 CONFLICT` (rides plan §1.2);
- assigns `RideService.AdvanceStatus` to use it and to return `ErrTransitionConflict` on
  `updated == false` **before** any event/broadcast/push/completion side effect (rides plan §1.2);
- owns the cross-transition lost-race regression table (rides plan §1.2 + §5.1).

**This plan does not add `ErrTransitionConflict`, does not add the repository method, and does not
duplicate that table.** It adopts them verbatim and adds only the arrival-specific obligation:

- after `[rides]_cancel_accept_race.md` lands, `AdvanceStatus` is CAS, so an accept-time evaluation
  racing a client `PUT /geo/driver/location` cannot duplicate the `driver_arrived` event/broadcast/
  push — exactly one writer wins;
- `EvaluateArrivalAtAccept` calls the same shared `AdvanceStatus` and **logs and swallows**
  `ErrTransitionConflict` on the arrival path (same failure mode as `EvaluateArrival`,
  `internal/service/arrival.go:82-86`), so a lost race never fails the location update and never
  makes the accept fail (`internal/handler/ride.go:681-696` stays `200`).

**Required regression test owned by this plan (new; not in the rides plan):**
accept-time evaluation + concurrent `PUT /geo/driver/location` for the same accepted ride with an
in-radius fix ⇒ exactly **one** transition, one `ride_events` row, one `ride.updated
driver_arrived` broadcast, one push; the loser returns `ErrTransitionConflict`, which the arrival
path logs and swallows; the accept still returns success. The per-edge matrix and the other
cross-transition cases are covered by the rides plan — reference
`api_plans/[rides]_cancel_accept_race.md` §1.2 and §5.1 rather than repeating them here.

Mocks move in lockstep with the rides plan, not this one: `tests/testutil/mock_repos.go:627` and
the fakes embedding `RideRepository` (`internal/service/ride_completion_fare_test.go:30`,
`internal/service/destination_test.go:44`, `internal/service/arrival_test.go:66`,
`internal/service/dispatch_test.go:142`) gain `UpdateRideStatusFrom` there. This plan only requires
that its own accept-path fakes (`internal/service/dispatch_test.go:32-75`) keep compiling against
that interface.

---

## 6. Never fail the accept

The accept is authoritative once `AssignDriver` commits (`internal/repository/ride_repo.go:411-427`).
Accept-time evaluation is additive and **best-effort**:

- `GEOFENCE_ENABLED=off` (or garbage → off, `internal/config/config.go:420-422`) ⇒ evaluator
  no-ops, regardless of the max-age knob.
- `GEOFENCE_ACCEPT_FIX_MAX_AGE_S` parsed to `0` (garbage/non-finite/≤0) ⇒ accept-time evaluation
  is skipped (fail-closed ops rollback), independent of `GEOFENCE_ENABLED`.
- No position row / `GetDriverLocation` error ⇒ skip silently (optionally log at debug).
- Fix `AgeS > cfg.Arrival.AcceptFixMaxAgeS` (SQL-side age, D1/D2) ⇒ skip silently.
- Evaluator panics? **No recover** — it is the same non-erroring `EvaluateArrival` path; a panic
  is a bug, and the seam returns no error so it cannot change the accept response mapping.
- Transition error (lost race `ErrTransitionConflict` from the `[rides]` CAS, illegal edge) ⇒
  logged and swallowed by `EvaluateArrivalAtAccept`, exactly like `EvaluateArrival`
  (`arrival.go:82-86`). This plan does not add the sentinel; it only consumes it.

The HTTP accept handler (`internal/handler/ride.go:681-696`) must remain `200
{"message":"ride accepted"}` regardless. The WS accept has no HTTP response; its event order is
D3=A (§4): `accepted` then `driver_arrived`.

---

## 7. Scope guard and nearby behaviour — D4=A (arrive-only entry point)

- **Do not remove the app-side fix** (`trip_screen.dart:52-58,200-201`). It remains the
  belt-and-braces path for clients on older builds and for a fix that arrives after accept.
- **Do not change the 80 m / 300 m semantics** (`internal/config/config.go:280-286`), the
  hysteresis/min-move rules, or the manual `PUT /:id/status` escape hatch.
- **D4 = A: accept-time evaluation is arrive-only.** It must never fire `ride.nearby`, must never
  prime or clear `nearStates`, and must never call `evaluateNearby`/`forgetNearState`. Nearby
  means "almost here" as the driver approaches (`arrival.go:108-177`, `nearbyPushMessage` at
  `:174-184`). Firing it instantly on accept (e.g. a driver 250 m away) would (a) duplicate the
  accepted notification, (b) prime `nearStates` before the trip has actually started moving, and
  (c) potentially push a "driver nearby" the instant the rider is told the ride was accepted.
  Keep the nearby branch on the live PUT path only.
- The arrive-only helper therefore contains **only** the arrive gate + `AdvanceStatus` and
  returns the arrival boolean; unlike `EvaluateArrival`'s arrive branch (`arrival.go:81-89`) it
  must not call `forgetNearState` (that mutates nearby hysteresis state).
- No new route, no response-shape change, no migration.

---

## 8. Implementation steps

1. **Config knob + parse tests (D1 sub-choice = env-tunable, default 60 s).**
   - `internal/config/config.go`: add `AcceptFixMaxAgeS float64` to `ArrivalGeofence`
     (`:267-273`), `defaultGeofenceAcceptFixMaxAgeS = 60` next to the other geofence defaults
     (`:282-287`), parse it in the `Arrival: ArrivalGeofence{...}` block (`:343-349`), and add
     `geofenceAcceptFixMaxAgeFromEnv()` (fail-closed; see §3) beside
     `geofenceEnabledFromEnv` (`:415-422`).
   - Parse tests alongside `TestGeofenceConfigFromEnv` (`internal/config/config_test.go:483-548`):
     unset → 60, valid → that value, garbage → 0 (skip), zero → 0, negative → 0.
2. **Model + repository read (no migration; D2/D6).**
   - `internal/model/geo.go` (`NearbyDriverResult`, `:27-34`): add
     `UpdatedAt time.Time `db:"updated_at" json:"-"`` and `AgeS float64 `db:"age_s" json:"-"``.
   - `internal/repository/geo_repo.go:125-138`: extend **`GetDriverLocation`** to select
     `updated_at` and `EXTRACT(EPOCH FROM (NOW() - updated_at))::double precision AS age_s`; keep its signature.
   - No `model.DriverFix`, no `GetDriverLocationWithAge`, no interface change
     (`GeoRepository` at `:11-29` is untouched).
3. **Mocks in lockstep (compile break otherwise).**
   - `tests/testutil/mock_repos.go` `MockGeoRepo.GetDriverLocation` (`:948`) → return the stored
     `UpdatedAt` and an `AgeS` knob (ages must be settable).
   - `internal/service/dispatch_test.go` `fakeGeoRepo` (`:32-75`) → same `AgeS` knob.
   - `internal/service/fare_test.go` `mockGeoRepo` (`:11-31`) → unaffected signature, verify.
4. **Arrive-only evaluator seam (D4).**
   - `internal/service/arrival.go`: factor the arrive gate out of `EvaluateArrival`
     (`:58-91`, gate at `:81-89`) into a private helper that does **not** call
     `forgetNearState`; add
     `EvaluateArrivalAtAccept(ride *model.Ride, driverID string, lat, lng float64) bool` that
     runs only the arrive gate (never `evaluateNearby`).
   - `internal/service/dispatch.go`: add `AcceptArrivalEvaluator` + setter (§2.1), and an
     `arrivalEvaluator` field on `DispatchService` (struct at `:63-77`).
5. **Accept call site (the one accept write; `acceptRide` after the rides chain head).**
   - Hoist the fix fetch out of `if driver != nil` (`internal/service/dispatch.go:430-465`) so
     the position row (`GetDriverLocation`, `:442`) is read even when `FindDriverByID` fails;
     keep the ETA use as-is.
   - **60 s SQL-side gate:** `loc != nil && cfg.Arrival.AcceptFixMaxAgeS > 0 &&
     loc.AgeS <= cfg.Arrival.AcceptFixMaxAgeS` (D1 default 60, SQL-side per D2). A parsed value
     of 0 (garbage/≤0) skips evaluation (fail closed).
   - **D3=A ordering:** call the evaluator **after** the accepted sends at
     `dispatch.go:479-480`, never before, so the wire order is `accepted` then
     `driver_arrived`. Before calling, set `ride.Status = "accepted"` and
     `ride.DriverID = &driverID` on the in-memory ride (the `AssignDriver` commit from §1 step 3),
     then call `s.arrivalEvaluator.EvaluateArrivalAtAccept(...)`. Do **not** return its result or
     any error; the accept must never fail.
   - `internal/router/router.go`: call `dispatchService.SetArrivalEvaluator(rideService)` next
     to `rideService.SetArrivalGeofence(cfg.Arrival)` (`:168`) after `NewDispatchService`
     (`:172`).
6. **Dependency, not a step: atomic CAS (D5, §5).** Do **not** add a repository method, sentinel,
   handler mapping, or cross-transition tests here. `UpdateRideStatusFrom` +
   `ErrTransitionConflict` and the `AdvanceStatus` rewrite are delivered by the open chain head
   `[rides]_cancel_accept_race.md` (§1.1–§1.3, §5.1). Stage `01` starts only after that lands;
   verify `AdvanceStatus` (`internal/service/ride.go:433-447`) already calls
   `UpdateRideStatusFrom` and returns the sentinel before side effects, then rely on it from
   `EvaluateArrivalAtAccept`.
7. **Accept handler:** no response-shape change; the HTTP accept keeps `200
   {"message":"ride accepted"}` (`internal/handler/ride.go:681-696`). This demonstrates the
   evaluation is not a handler concern.
8. **Docs:** update `api_plans/STATUS.md` when landing; if the config is user/ops-visible,
   document `GEOFENCE_ACCEPT_FIX_MAX_AGE_S` (default 60; `≤0`/garbage = skip accept-time
   evaluation) in `RIDER_API_GUIDE.md` near the existing `GEOFENCE_*` note (`:781`). The
   `config.go` field comment is the source of truth either way.

---

## 9. Tests

- **Unit — evaluator (`internal/service/arrival_test.go`).** Reuse `acceptedArrivalRide`,
  `atMetres`, `testGeofenceConfig`.
  - `EvaluateArrivalAtAccept` inside 80 m advances exactly once.
  - Outside 80 m does **not** advance and records **no** nearby push (`recordingNotifier` stays
    empty) and leaves nearby hysteresis state untouched (call it twice around a nearby crossing;
    the live PUT path must still emit its own one-per-crossing `ride.nearby`).
  - Disabled config, wrong driver, non-accepted ride ⇒ no-op.
  - A stale/a fresh `AgeS` is not in the evaluator; assert the evaluator advances regardless of
    age (freshness belongs to dispatch, D1/D2).
- **Unit — config (`internal/config/config_test.go`).** Parse tests for
  `GEOFENCE_ACCEPT_FIX_MAX_AGE_S`: unset/empty → 60; valid (e.g. 45) → 45; garbage → 0 (skip);
  `0` → 0; negative → 0. Confirm `GEOFENCE_ENABLED=off` still yields `Enabled=false` while the
  max-age value is parsed independently.
- **Unit — accept path (`internal/service/dispatch_test.go`).** Extend `fakeGeoRepo` with an
  `AgeS` knob and add a recording evaluator.
  - Fresh fix (`AgeS <= 60`) + evaluator ⇒ `AcceptRide` returns nil and calls the evaluator once
    with the accepted ride, driver id and fix coordinates.
  - `AgeS > 60` ⇒ evaluator not called; use 60.001 to pin the boundary, not just a clearly old
    value.
  - Configured max age of 0 (garbage/≤0) ⇒ evaluator not called.
  - Geo read error / no row ⇒ accept still nil, evaluator not called.
  - Evaluator "fails" (returns false or its own transition is lost) ⇒ accept still nil.
  - D3=A broadcast order: both users get `accepted` before the evaluator runs; the evaluator
    then causes exactly one `driver_arrived` broadcast, never `driver_arrived` before
    `accepted`.
- **Accept-time evaluation vs concurrent client PUT (required; owned by this plan).** Drive the
  accept-time evaluator and a concurrent `PUT /geo/driver/location` for the same accepted ride with
  an in-radius fix. Assert **exactly one** `accepted → driver_arrived` transition, one
  `ride_events` row, one `ride.updated driver_arrived` broadcast, and one push; the loser returns
  `ErrTransitionConflict` from the rides plan's CAS, the arrival path logs and swallows it, and the
  accept still returns success (`200`). Test at service level with a barrier/`await` (never by
  sleeping) and end-to-end through `tests/arrival_geofence_test.go`.
  The general cross-transition lost-race matrix (in_progress, completed, cancels, illegal edges)
  belongs to `api_plans/[rides]_cancel_accept_race.md` §1.2/§5.1 — do not re-declare it here.
- **Handler/end-to-end (`tests/arrival_geofence_test.go`).** The existing harness boots the real
  router with mock repos.
  - `POST /api/v1/driver/rides/:id/accept` for a pending ride whose mocked last fix is inside
    80 m ⇒ **200** and the ride row becomes `driver_arrived` with **no** subsequent
    `PUT /geo/driver/location`.
  - Same accept with a stale fix ⇒ **200**, ride stays `accepted`.
  - Accept with no position row ⇒ **200**, ride stays `accepted`.
  - A subsequent `PUT /geo/driver/location` after accept-time arrival must not emit a second
    `driver_arrived` event (assert exactly one event and one broadcast).
- **Repository integration (`internal/repository/*_integration_test.go`, `//go:build integration`).**
  - `GetDriverLocation` returns a DB-computed `AgeS` that tracks `updated_at` (insert a row with
    `updated_at = NOW() - interval '90 seconds'`, assert `AgeS ≈ 90`, i.e. it is not app-clock
    derived).
  - Existing `TestLivenessWindowBindsInPostgres` remains the pattern for DB-only assertions.
  - The `UpdateRideStatusFrom` integration tests (stale expected status, `no_driver_available`,
    concurrent CAS) are part of `[rides]_cancel_accept_race.md` §5.4, not this plan.
- **Regression:** all existing `arrival_*` suites must pass unchanged (the PUT path still
  advances and still reports the additive nearby fields); `GET /drivers/:id/location` JSON must
  not gain `updated_at`/`age_s` (both are `json:"-"`), pinned by the existing location handler
  test.

---

## 10. Rollout / rollback / verification

- **Gate:** `GEOFENCE_ENABLED` (`internal/config/config.go:420-422`; installed via
  `internal/router/router.go:168`). `off` disables accept-time evaluation along with the live
  geofence, restoring exactly today's behaviour. No new required env (the new knob has a 60 s
  default).
- **Ops rollback without redeploy:** set `GEOFENCE_ACCEPT_FIX_MAX_AGE_S=0` (or any
  garbage/non-positive value) ⇒ skip accept-time evaluation while the live geofence keeps
  working. This is independent of `GEOFENCE_ENABLED`.
- **No migration**, so binary rollback remains the previous binary. The max age ships as **60 s**;
  unset/empty means 60, a valid positive value is that many seconds, and garbage/non-positive
  fails closed (skip accept-time evaluation), never open.
- **Metrics/logs:** log at debug/info when accept-time evaluation is skipped for staleness or a
  missing fix, and log the lost-race `ErrTransitionConflict` at the existing `arrival.go:83`
  site. Don't add a new user-visible error on the accept path.
- **Verification:**
  ```bash
  make test
  make lint
  make test-integration          # DB-backed age_s test; CAS tests belong to [rides]; run one Go agent at a time
  gofmt -w internal/config/config.go internal/config/config_test.go \
           internal/model/geo.go internal/repository/geo_repo.go \
           internal/service/arrival.go internal/service/dispatch.go \
           internal/router/router.go \
           tests/testutil/mock_repos.go \
           internal/service/dispatch_test.go internal/service/fare_test.go \
           internal/service/arrival_test.go tests/arrival_geofence_test.go
  go vet ./...
  ```

---

## 11. Decisions (D1–D6) — all resolved

1. **D1 = A — max accept-time fix age 60 s, env-tunable.** `GEOFENCE_ACCEPT_FIX_MAX_AGE_S` ships
   default **60 s**; unset/empty → 60, valid positive → that many seconds, garbage/non-finite/≤0 →
   0 = **skip accept-time evaluation** (fail-closed; ops rollback without redeploy). See §3/§10.
2. **D2 = A — SQL-side freshness.** `AgeS` from `EXTRACT(EPOCH FROM (NOW() - updated_at))` in the
   `GetDriverLocation` query; never `time.Since`/app clock.
3. **D3 = A — keep both WS patches.** `accepted` (with Driver/Pickup/Dropoff/EtaSeconds) is sent
   first, then `driver_arrived` (RideID/Status/Timestamp only) from the arrival transition; the
   evaluation runs **after** the accepted sends. Zero client change. B and C are considered and
   rejected in §4.
4. **D4 = A — arrive-only entry point.** `EvaluateArrivalAtAccept`; never `ride.nearby`, never
   touches nearby hysteresis state (including `forgetNearState`).
5. **D5 = A — atomic CAS behavior (owned by `[rides]_cancel_accept_race.md`, adopted here).**
   The human approved the CAS semantics, but the canonical symbols live in that open chain head:
   `UpdateRideStatusFrom(rideID string, expectedFrom []string, status string, timestamp *time.Time)
   (updated bool, err error)` used by `AdvanceStatus`, loser returns `ErrTransitionConflict` (409)
   with no event/broadcast/push/completion side effects. This plan adds neither the method nor the
   sentinel and does not repeat the cross-transition table (rides plan §1.2, §5.1). Stage `01`
   cannot land before that plan; its only CAS obligation is the accept-time-evaluation + concurrent
   `PUT /geo/driver/location` single-transition test in §9.
6. **D6 = B — no `model.DriverFix`.** `NearbyDriverResult` gains `UpdatedAt` (`db:"updated_at"`)
   and `AgeS` (`db:"age_s"`); `GetDriverLocation` is extended, not duplicated.

**Remaining open: none at the product/decision level.** The plan is decision-complete; the only
open items are sequencing and implementation — it **cannot land before**
`[rides]_cancel_accept_race.md` (the CAS owner), and every step in §8 is still unstarted.

---

## 12. Evidence corrections to the briefed facts

- `GetDriverLocation` at accept is `internal/service/dispatch.go:442`, not `:438`.
- `DriverLivenessWindow` is `internal/repository/geo_repo.go:39` (the comment block above it
  runs `:31-38`), not `:46-60`.
- The `driver_arrived` broadcast/push is `internal/service/ride.go:606-615`, not `:544-554`.
  **Drift found and corrected:** the landed `[arrival]` STATUS entry cited `ride.go:544-554` (and
  stale config line ranges); `STATUS.md` now cites `:606-615` and the current
  `internal/config/config.go:267-273,282-287,343-349,420-422`. (The `AdvanceStatus` broadcast
  starts at `:450`, the shared send/push at `:606-615`.)
- **Handler-level evaluation would miss the primary WS accept path**
  (`internal/websocket/hub.go:184-191` → `internal/service/dispatch.go:364-372` →
  `acceptOfferedRide` at `:296-307` → `AcceptRide`). The recommendation is therefore
  `DispatchService.AcceptRide`, not the handler.
- **The arrival transition is not DB-idempotent today.** `UpdateRideStatus`
  (`internal/repository/ride_repo.go:299-325`, interface `:25`) has no status precondition; two
  concurrent `AdvanceStatus` calls can both emit `driver_arrived`. The CAS fix
  (`UpdateRideStatusFrom` + `ErrTransitionConflict`) is owned by
  `[rides]_cancel_accept_race.md` §1.1–§1.2; this plan depends on it and adds only the accept-time
  race test (§9).
- **The accepted broadcast is at the end of `AcceptRide`** (`dispatch.go:479-480`); under D3=A
  the accept-time evaluation follows it, preserving `accepted → driver_arrived` ordering.
- **`AcceptRide` fires no offline push** (`dispatch.go:400-482`), so rejected D3 option C's
  "double notification" premise is false; the only accept-time push is `AdvanceStatus`'s
  `driver_arrived` push (`ride.go:613-615`), which `notifyOffline` suppresses for connected users.
