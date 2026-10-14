---
tag: ontrip
depends_on:
  - "[tracking] typed live driver tracking (rider_app_plans/STATUS.md → Landed `[tracking]`)"
  - "[ontrip] ETA honesty (rider_app_plans/STATUS.md → Landed `[ontrip]`)"
status: open
---

# [ontrip] Live driver-arrival ETA for the rider

> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> Verification). **Independent** — every prerequisite is landed capability named in
> `rider_app_plans/STATUS.md`, not an open plan, so this file is **unnumbered**
> (`depends_on` names Landed capability, not an open-plan filename).
>
> **Tag call: `ontrip`, not `tracking`.** The deliverable is the *in-trip ETA* — its value, its
> per-status semantics and its honesty contract — which Landed `[ontrip]` already owns (“ETA honesty”,
> `trip_eta.dart`; the live trip route). Landed `[tracking]` owns the *driver-fix transport*
> (`driver_tracking_provider.dart`) that this plan **consumes unchanged**. Splitting the ETA across two
> tags would scatter one capability; keeping the arrival ETA with the trip ETA keeps the honesty
> contract in one place.

## What already exists (the ETA is real, but static and lost on reconnect)

This is **not** greenfield. On accept the API computes a **real** driver→pickup ETA from the routing
engine and pushes it once over WebSocket:

- Route compute + fallback: `internal/service/dispatch.go:290-319`; the placeholder `300` is set at
  `:294` and only avoided when routing **and** the driver location both succeed (`:316-318`).
- Event field: `RideUpdateData.EtaSeconds int \`json:"eta_seconds,omitempty"\``
  `internal/websocket/messages.go:17`, sent at `dispatch.go:342`.
- Rider stores it: `RideState.etaSeconds` `rider_app/lib/features/home/data/ride_status_provider.dart:16`,
  written in the `pending` branch `:90` and every other `ride.updated` `:106`.
- Rider displays it in the active-trip driver sheet:
  `rider_app/lib/features/home/presentation/active_ride_screen.dart:654-658` → `ValueKey('trip-eta')`
  `:715-728`.
- Honesty helper: `rider_app/lib/features/home/data/trip_eta.dart:5,12-17` — `300` (and null /
  non-positive) means **unknown**, rendered `ETA unavailable`, rounded **up** to whole minutes.

**So the plan is about closing three gaps, not building from zero.**

## The gaps to close

1. **Static (never refreshes).** The ETA is computed only on accept. `driver.location` WS events carry
   lat/lng/heading/speed only (`internal/websocket/messages.go:76-83`, emitted
   `internal/handler/geo.go:79-89`) and updating them does **not** recompute the ETA. The rider folds
   each fix into `RideState.driverLocation` (`driver_tracking_provider.dart:97,123-136`;
   `applyDriverLocation` `ride_status_provider.dart:138-140`) with no ETA touch. A 10-minute drive shows
   the accept-time number for the whole drive.
2. **Lost on reconnect / cold start.** `GET /rides/current` (`internal/handler/ride.go:240-283`) and
   `GET /rides/:id` (`:295+`) return `model.Ride`, which has **no** ETA field
   (`internal/model/ride.go:5-91`); `eta_seconds` exists only in `/geo/eta` and the WS event. If the
   accept `ride.updated` is missed, `RideState.etaSeconds` stays `null` forever → permanent
   `ETA unavailable` while the driver is en route. `current_ride_provider.dart` only forwards fields
   present in the payload (`updateFromCurrentRide` `ride_status_provider.dart:115-120`).
3. **Wrong semantics.** The same **driver→pickup** ETA is shown for **every** status, including
   `onTrip`, where it is meaningless. `active_ride_screen.dart:653-658` does not branch on status
   (`_getStatusText` `:786-797` does); a `driverArrived` state should not show a countdown at all.

## Landed prerequisites (all in the code; named in STATUS.md)

| Capability | Evidence |
| --- | --- |
| Accept-time driver→pickup ETA over WS + the `300` placeholder | `internal/service/dispatch.go:290-319,342`; `internal/websocket/messages.go:17`; `rider_app/lib/features/home/data/ride_status_provider.dart:16,90,106` |
| ETA honesty contract (`300` = unknown, round up) | `rider_app/lib/features/home/data/trip_eta.dart:5,12-17` |
| Typed live driver tracking (WS + `GET /drivers/{id}/location` poll, 5 s / 10 s silence) | `rider_app/lib/features/home/data/driver_tracking_provider.dart:57-58,75-77,97,123-148`; `internal/websocket/messages.go:76-83`; `internal/handler/geo.go:79-89`; `internal/handler/geo.go:211-217` (the GET, auth-only — no ownership check) |
| Typed state the screen already holds | `RideState.driver`, `RideState.driverLocation` `ride_status_provider.dart:13-14`; `DriverInfo.fromJson` / `DriverLocation.fromJson` `rider_app/lib/features/home/model/driver.dart:47-60,101-109` |
| A ready-made ETA endpoint (defined, **currently unconsumed**) | `ApiEndpoints.eta` `rider_app/lib/core/api/endpoints.dart:10`; handler `internal/handler/platform.go:529-548`; shape `internal/handler/responses.go:231-235`; routed `internal/router/router.go:243` (`GET /api/v1/geo/eta`, Bearer auth) |
| The trip route + its injectable 30 s refresh (the pattern to mirror) | `rider_app/lib/features/home/data/trip_route_provider.dart:53-54,97-110` |
| The accept payload already carries the pickup pin (`rideData['pickup']`) | `internal/service/dispatch.go:330`; read at `active_ride_screen.dart:248-256`; the REST ride carries `pickup_lat/lng` (`internal/model/ride.go:10-11`) |
| The driver app already publishes its location (`PUT /geo/driver/location`) | `internal/router/router.go:239` — **no driver-app change is required for any option below** |

## Pivotal decision — where the live ETA comes from

> **Recommendation: R1 (client-computed, rider-only).** It is the only option that adds **no API
> change, no `shared/` change and no driver-app change**, yet closes both Gap 1 and Gap 2 (on rejoin
> the poll yields a fix → the client recomputes). It must not silently win — this is the decision to
> put to the human.

| Option | How | Tradeoffs | Domain touch |
| --- | --- | --- | --- |
| **R1 — Client-computed live ETA (RECOMMENDED)** | On each live driver fix while `driverApproaching`, the rider computes driver→pickup via the routing engine and writes it into `RideState.etaSeconds` (throttled). | **+** No API change, no `shared/`, no driver-app change. **+** Fixes Gap 2 (the poll re-supplies a fix after reconnect). **+** Reuses an existing, already-defined endpoint. **−** The computation is duplicated per rider (one extra route call per active ride on the rider's behalf), and the number can drift from a server-computed one. | rider only |
| **R2 — Server-pushed live ETA** | The API recomputes driver→pickup on each `PUT /geo/driver/location` for the active ride and adds `eta_seconds` to the `driver.location` event (or emits `ride.updated`). | **+** One source of truth; no client route calls. **−** Puts a route computation on the **hot location path for every active ride**; needs bounding/rate-limiting. **−** An `api_plans` change (new field on `DriverLocationData`, `internal/websocket/messages.go:76-83`). | **API + rider** (cross-domain) |
| **R3 — Hybrid** | Server pushes when available; client computes the fallback. | **+** Most robust. **−** Largest surface, two code paths, two sources of truth to reconcile. | API + rider |

Under R1, the endpoint choice is **`GET /api/v1/geo/eta`** (not `/navigation/route`): its payload is
exactly `{eta_seconds, distance_meters, is_estimate}` (`responses.go:231-235`) with **no polyline** we
would throw away, and `ApiEndpoints.eta` is already declared but unconsumed — this gives it its first
consumer. It returns **500** on routing failure (never a 4xx), consistent with the API error-contract
invariant, so the client can stay honest on failure.

## Decisions to lock (recommendations; nothing here is silently chosen)

### D1 — Per-status semantics

- `driverApproaching` → **show the live arrival ETA** (the whole point of this plan).
- `driverArrived` → **explicit arrived state, no countdown** (e.g. `Your driver has arrived`). A
  countdown to an event that already happened is a lie.
- `onTrip` → **no arrival ETA row.** The driver→pickup time is meaningless once moving. **On-trip ETA
  (pickup→dropoff remaining time) is OUT OF SCOPE** and is a separable plan: the trip route's
  `totalDurationS` (`trip_route_provider.dart:198-206`) is the **full itinerary** duration
  (pickup→dropoff), not the *remaining* time from the driver's current position, so it cannot be
  reused as-is.
- `matching` / `completed` / `cancelled` / `noDriverAvailable` → **no arrival ETA row** (matching has
  its own screen; terminal states have no ETA). **Recommendation: D1 as above.**

### D2 — Reconnect / cold start

- **Under R1 the poll fixes it — but only with one small app-local addition.** On a cold `/rides/current`
  the payload has `driver_id` but **no nested `driver` object** (`internal/model/ride.go:8`), and
  `updateFromCurrentRide` never maps `driver_id` into state, so `RideState.driver` stays `null` and
  `driver_tracking_provider.attach(...)` gets `null` → it can never poll the location → no fix → no ETA.
  **Recommendation: include the app-local fix** — source the driver id from `rideData['driver_id']`
  (already stored at `ride_status_provider.dart:108`) and feed the tracker, so R1's "reconnect closes
  Gap 2" claim is actually true. No API change.
- **Alternative (not recommended):** add `eta_seconds` to `GET /rides/current`/`GET /rides/:id`. That is
  an `api_plans` dependency (a server-computed value embedded in `model.Ride`) and should be a
  **separate API plan** if the human wants it, not folded in here.

### D3 — Placeholder policy

- **Keep `trip_eta.dart`'s contract exactly:** `300` = unknown, never re-interpreted
  (`trip_eta.dart:5,13`). The client compute must **never write `300` or `0`**.
- **On compute failure** (500 / malformed / timeout): **retain the last known `RideState.etaSeconds`**
  (which may itself be the accept-time `300` ⇒ still `ETA unavailable`) — do not clear it to `null` and
  do not invent a value. `RideState.copyWith`'s `?? this.etaSeconds` already gives this for free; the
  design must not defeat it.
- **`is_estimate: true`** (a straight-line fallback from `/geo/eta`): **recommendation — accept it**
  (the driver's position is real and the API computed it; the number is advisory, not money), and keep
  the plain `ETA X min` label for scope control. A `~` prefix to mirror the Home preview's
  `Estimated ` convention is a listed fallback if the adversarial review demands a visual distinction.

### D4 — Throttle policy

- **Interval-primary** refresh while `driverApproaching`, injectable like
  `tripRouteRefreshIntervalProvider` (default **30 s**, matching the existing trip-route cadence).
- **Early trigger on movement:** recompute before the next tick when the driver has moved
  ≥ `driverEtaMinMovementM` (**150 m**, injectable) from the fix the last ETA was computed from, with a
  **5 s floor** between requests so GPS jitter cannot spam the endpoint.
- **Immediate refresh** on the first fix after entering `driverApproaching` (covers the
  accept-then-fix race and reconnect; if `driverLocation` is still null, seed it from
  `DriverInfo.location`, already parsed at `driver.dart:36,56-58` but currently unused).
- **Must stop** on `driverArrived` / `onTrip` / terminal status and in `dispose()`, mirroring
  `_tripRoute.stop()` / `_tracker.stop()` `active_ride_screen.dart:126-128`.

### D5 — Label

- **Keep `ETA X min`** as the base (`active_ride_screen.dart:658`; `trip_eta.dart:12-17`).
- **Surface distance too (recommended):** when `/geo/eta` supplied `distance_meters`, render
  `'{km} km · ETA {min} min'` (e.g. `2.3 km · ETA 4 min`), consistent with the estimate sheet's
  `'$km km · ~$minutes min'` (`ride_estimate_sheet.dart:182-186`) and the Home preview's
  distance+time row (`home_screen.dart:842-858`). Fall back to the plain `ETA X min` / `ETA unavailable`
  string when distance is unknown, and to the explicit arrived/no-ETA text per D1. Keep the
  `ValueKey('trip-eta')`; the exact string change is what the existing two widget assertions
  (`active_ride_screen_test.dart:1097,1115`) must be updated to.

## Recommended design (R1)

1. **New app-local provider** `driverEtaProvider` (a `StateNotifier`, no router/`shared` dependency) in
   `rider_app/lib/features/home/data/driver_eta_provider.dart`. It:
   - watches `RideState.status` and `RideState.driverLocation` (and falls back to
     `RideState.driver?.location`);
   - reads the pickup pin from `RideState.rideData['pickup']` (`{lat,lng}`) and, when absent, from
     `rideData['pickup_lat']`/`pickup_lng` (the `/rides/current` shape) — so cold start works;
   - calls `GET /api/v1/geo/eta` with `from = driver fix`, `to = pickup pin` under D4's throttle;
   - on success writes the value into `RideState` via a **new** `RideStatusNotifier` method (e.g.
     `applyLiveEta(int seconds, {double? distanceM})`) that preserves the existing field on a failed
     compute (D3) — this is the only change to the landed state machine, and it is additive;
   - exposes injectable `refreshInterval` / `minMovementM` for deterministic tests.
2. **`RideState`** gains one additive field `etaDistanceM` (nullable) and a matching `copyWith` entry,
   so the label can render distance without a second source.
3. **`active_ride_screen.dart`** branches the driver-sheet ETA row on status per D1, starts/stops
   `driverEtaProvider` alongside `_tracker`/`_tripRoute` (`initState` `:58-92`, `dispose` `:119-130`),
   and renders the D5 label.
4. **`ride_status_provider.dart`** gains the additive `applyLiveEta`; D2 additionally sources the
   driver id for the tracker (either via a new `RideState.driverId` or by having
   `driver_tracking_provider.attach` accept `RideState`/`rideData['driver_id']`).

### Boundaries (explicit)

- **`shared/` requires NO change.** No new shared symbol is introduced, so the barrel / ADS-only
  re-export rule is **not exercised** and no shim is minted. (If a future decision moves the compute to
  shared, that is a new decision, not this plan.)
- **No driver-app change** under R1/R3 — the driver already publishes `PUT /geo/driver/location`
  (`router.go:239`).
- **No `api_plans/` change** under R1. Under **R2/R3 the API owner is `api-planner`**: the exact change
  would be a new `EtaSeconds int` on `DriverLocationData` (`internal/websocket/messages.go:76-83`)
  computed in `UpdateDriverLocation` (`internal/handler/geo.go:79-89`) via `navSvc.GetRoute` to the
  ride pickup, with hot-path bounding/rate-limiting; the rider then parses it in
  `_handleDriverLocation` (`ride_status_provider.dart:122-128`).
- **On-trip ETA is out of scope** (D1) — a separate plan if wanted.

## Tests (new / changed)

| Test | File | Asserts |
| --- | --- | --- |
| New `driver_eta_provider_test.dart` | `rider_app/test/features/home/data/driver_eta_provider_test.dart` (new; `mocktail` + `http_mock_adapter`, mirroring `driver_tracking_provider_test.dart:12-45`) | computes on the first fix while `driverApproaching`; one `GET /geo/eta` with the driver fix as `from`; the value lands in `RideState.etaSeconds`; **throttle** — a second fix inside the interval makes no second request; a ≥150 m move triggers an early request; **failure retention** — a 500 leaves the previous value intact; **no compute** when status is `onTrip`/`driverArrived`; `stop()`/`dispose()` cancels the tick |
| Extend ETA-honesty group | `rider_app/test/features/home/data/trip_route_provider_test.dart:212-230` | `etaLabel` still maps `300`/`0`/negative/null → `null` and rounds up (guard the contract this plan must not change) |
| Extend state tests | `rider_app/test/features/home/data/ride_status_provider_test.dart:70-90` | `applyLiveEta` writes `etaSeconds`/`etaDistanceM`; a failed compute does not clear them; `updateFromCurrentRide` exposes `driver_id` for the tracker (D2) |
| Update widget tests | `rider_app/test/features/home/presentation/active_ride_screen_test.dart:1085-1118` | `driverApproaching` shows the live ETA (e.g. `ETA 4 min` / `2.3 km · ETA 4 min`); the `300` placeholder still reads `ETA unavailable` (`:1097`); `driverArrived` shows the arrived text and **no** `trip-eta` countdown; `onTrip` renders no arrival countdown |
| New cold-start widget test | same file | with no accept event (WS missed) and a `/rides/current` `driver_id`, the driver-location poll + client compute restore the ETA — the Gap-2 regression guard |

Existing tests that must be updated, not deleted: `active_ride_screen_test.dart:1085-1118` (string and
status semantics), `ride_status_provider_test.dart:70-90` (additive field/method).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` must be clean; `melos run test` green across the three packages (rider / driver /
  shared).
- **UNVERIFIABLE in this WSL harness:** any Android/on-device behavior — the live ETA refresh under a
  real GPS fix stream, the reconnect path after the OS kills/restores the app, and battery/cadence
  behavior. Close on an Android host with `flutter run` on the device: accept a ride, confirm the ETA
  changes as the driver moves, force-stop/relaunch and confirm the ETA returns, and confirm no
  `/geo/eta` calls continue after `driverArrived`/trip end. `make flutter-analyze` / `make flutter-test`
  are **broken from this WSL tree** — do not use them.

## Open inputs / unknowns

1. **R1 vs R2 vs R3** — the pivotal human decision above.
2. **On-trip ETA** — deliberately out of scope; decide later whether a separable remaining-trip ETA plan
   is wanted (would need a route from the driver's live position to the dropoff, not the full itinerary).
3. **Distance on the label** — recommended yes; confirm the exact separator/format the human wants
   (Home preview and estimate sheet differ slightly today).
4. **`is_estimate` handling** — recommended accept as-is; confirm whether a `~`/“approximate” marker is
   required by honesty review.
5. **D2 scope** — confirm the app-local driver-id-from-`rideData` addition is in scope (recommended), or
   whether the human prefers the separate API `eta_seconds`-on-`/rides/current` dependency.

## Invariants touched (from STATUS.md)

- “An `etaSeconds` of `300` is *unknown*, never a rendered ETA” (`trip_eta.dart:5`) — preserved by D3.
- The API error contract (never answer an outage with 4xx) — `/geo/eta` already returns 500 on failure;
  the client must not convert that into a fabricated time.
- Re-export-shim / no-new-shims rule — this plan adds **no** shared symbol, so no barrel/shim edit.
