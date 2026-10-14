---
tag: arrival
depends_on: ["api_plans/[arrival]_proximity_arrival_geofence.md"]
status: open
---

# 01 [arrival] Auto arrival — remove the manual "Arrived at pickup" button

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification). On-device GPS cadence is **UNVERIFIABLE in this WSL tree**; the
> broadcast-driven widget/provider probes are the proxy (closing steps under Verification).
>
> **Numbered `01_`** because `depends_on` names the **open** API plan
> `api_plans/[arrival]_proximity_arrival_geofence.md` (`.opencode/skills/plan-management/SKILL.md`).
> **Nothing here is claimed landed.**

## Goal

Remove the manual "Arrived at pickup" button. The API owns arrival: its proximity geofence advances
the ride to `driver_arrived` and broadcasts `ride.updated`; the driver app reflects the new stage
automatically with no driver-sent transition.

## Canonical contract — adopt VERBATIM (owned by `api_plans/[arrival]_proximity_arrival_geofence.md` §2)

The API plan is the **canonical owner** of this contract. The driver app ships shape-identical
behavior; if the API plan changes a shape, this plan is re-synced before it lands.

- **Trigger / decision is server-side.** On each successful `PUT /api/v1/geo/driver/location` (and the
  batch path's final fix), for the caller's active ride **in status `accepted`**, the server computes
  the straight-line distance fix→`ride.pickup` and, at `d ≤ GEOFENCE_ARRIVE_RADIUS_M` (**default
  80 m**), advances the state machine with actor **`"system"`**.
- **Broadcast (exact shape):**

  ```json
  {"type":"ride.updated","data":{"ride_id":"<id>","status":"driver_arrived","timestamp":"<RFC3339>"}}
  ```

  Sent to **BOTH** rider and driver (`api_plans/[arrival]_proximity_arrival_geofence.md` §2.3 step 4).
- **The driver never sends `driver_arrived` itself.** The manual
  `PUT /api/v1/driver/rides/:id/status {status:"driver_arrived"}` stays **only** as a server
  recovery/testing seam (and the optional secondary in D2) — no primary UI.
- **Idempotent:** once the row is `driver_arrived` (or later), the status is no longer `accepted`, so
  the geofence is skipped; the ride is never re-advanced or re-notified.
- **Config knobs** (API-owned; the app hardcodes none): `GEOFENCE_ARRIVE_RADIUS_M` default **80**,
  `GEOFENCE_ENABLED` default **on**.

## Driver today (evidence)

- The trip screen renders the manual primary button at `TripStage.enrouteToPickup` —
  `driver_app/lib/features/trip/presentation/trip_screen.dart:566-571`
  (`label: 'Arrived at pickup'`, `onPressed: onAdvance`).
- `onAdvance` → `TripNotifier.advance()`, which maps `enrouteToPickup → 'driver_arrived'` and `PUT`s
  it — `driver_app/lib/features/trip/providers/trip_notifier.dart:162-189` (the mapping
  `:170-177`, the `PUT` `:180-183`).
- The automatic path **already works**: the `ride.updated status=driver_arrived` patch is merged by
  `RideStateNotifier._onRideUpdated` — `driver_app/lib/core/ride/ride_state_notifier.dart:81-101` —
  and `TripNotifier._stageFromStatus` maps it to `TripStage.arrived` —
  `driver_app/lib/features/trip/providers/trip_notifier.dart:131-139` (`'driver_arrived' =>
  TripStage.arrived`). So the button only duplicates a transition the broadcast already drives.

## Scope (app-local only)

1. **Remove the manual primary button at `enrouteToPickup`** —
   `trip_screen.dart:566-571`. The stage must advance solely from the incoming
   `ride.updated status=driver_arrived` (the `:81-101` → `:131-139` path above), which rebuilds
   `TripStage.arrived` and renders the existing "Start trip" button (`trip_screen.dart:572-576`).
   Keep the stage's non-interactive copy ("Drive to the pickup", `:539`); the screen needs no button
   while en route — optionally a passive "Waiting for arrival…" caption, not a control.
2. **Stop `advance()` from ever sending `driver_arrived`** —
   `trip_notifier.dart:170-177`. With the button gone this case is dead, but leaving it is a latent
   regression (a future caller could re-introduce the manual transition). Return `null` for
   `TripStage.enrouteToPickup` (or remove the case) so no driver code path sends `driver_arrived`.
   `arrived → in_progress` and `driving → completed` stay exactly as they are.
3. **Do not build UI on the removed server route.** `POST /driver/rides/:id/notify-arrival` is
   redundant (notify-only, no transition); the endpoint constant
   `driverRideNotifyArrival` (`driver_app/lib/core/api/endpoints.dart:38`) has no call site and the
   API plan (`§3 D5`) removes the route. Leave the constant untouched here — it is API-owned cleanup.
4. **No new manual fallback by default** (see D2).

## Decisions to surface

### D1 — How the stage advances (fixed by the contract)

The stage advances **only** from the server's `ride.updated status=driver_arrived` broadcast already
merged at `ride_state_notifier.dart:81-101` → `trip_notifier.dart:131-139`. No client heuristic, no
client-side distance computation, no driver-sent transition. No option to debate — the API is
authoritative (the API plan's D1).

### D2 — Optional secondary "Report arrived" control?

- **Recommended: none.** The product request is "remove the button; the app reflects it
  automatically". No primary and no secondary keeps one source of truth and avoids a driver racing
  the geofence.
- Alternative: an optional secondary "Report arrived" (same `PUT /:id/status {driver_arrived}`) for
  the GPS-denied / wrong-parking case, as the API plan's D6 allows. If taken it must be a **secondary**
  variant, clearly a fallback, and must not be the default path; the server needs no change. Default
  stays none unless the product asks.

### D3 — Copy and affordance while en route

- Recommended: keep "Drive to the pickup" and show no button (optionally a passive caption). The
  arrival is now an event the driver observes, not an action they perform.

## Tests to add/change

- `driver_app/test/features/trip/presentation/trip_screen_test.dart:292-314` —
  **rewrite** "enrouteToPickup offers arrival and advances to arrived": assert **no**
  `trip-primary-button` at `enrouteToPickup`, then broadcast `ride.updated status=driver_arrived`
  (`broadcast(status: 'driver_arrived')`, fixture `driver_app/test/support/trip_fixtures.dart:16-44`)
  and assert the screen reaches "Arrived at the pickup" + "Start trip" with **no `PUT`**.
- `driver_app/test/features/trip/presentation/trip_screen_test.dart` — **new regression:** after the
  broadcast-driven arrival, `verifyNever(() => mockDio.put(ApiEndpoints.driverRideStatus('r1'), data:
  any(named: 'data')))` is sent with `driver_arrived` (the driver never sends it).
- `driver_app/test/features/trip/providers/trip_notifier_test.dart:151-165` —
  **change** "enrouteToPickup puts driver_arrived and adopts the response": `advance()` at
  `enrouteToPickup` performs **no** `PUT` and leaves the stage unchanged. Keep the
  `arrived → in_progress` and `driving → completed` tests (`:167-207`).
- Keep `trip_notifier_test.dart:126-133` ("driver_arrived maps to its own arrived stage") — the
  broadcast-driven path this plan relies on.
- Keep `trip_screen_test.dart:316-338` ("arrived starts the trip…") — the `arrived` button is
  untouched.

## Cross-domain

- **API is the canonical owner.** Adopt `api_plans/[arrival]_proximity_arrival_geofence.md` §2
  verbatim; do not re-derive field names, thresholds or semantics. Changes there require re-syncing
  this plan before landing.
- **Coordination with open driver `[ontrip]` plans (all touch `trip_screen.dart`):**
  `[ontrip]_live_destination_update.md` (`_syncRoute`/fit-key area) and
  `[ontrip]_itinerary_next_stop.md` (`_targetFor`, map markers, `_StageControls`). Removing one
  button from the `_StageControls` switch is independent of both, but land them in any order and
  re-run the trip suite after all three.
- **Rider sibling** `rider_app_plans/01_[arrival]_auto_arrival_nearby.md` (rider-owned; consumes the
  same broadcast and the nearby signal). Do not edit `rider_app_plans/`.
- **No `shared/` change.** The parse/merge path is landed in `driver_app`.

## Open inputs / unknowns

| # | Unknown | Resolution |
| --- | --- | --- |
| 1 | D2 — secondary "Report arrived" control | Default none (product request). Confirm with the product owner. |
| 2 | `GEOFENCE_MIN_MOVE_M` vs the driver publish cadence | API plan §7 open input #2; the driver publishes ≥5 s throttled (`driver_app_plans/STATUS.md` → Landed `[online]`). No app change either way. |
| 3 | `notify-arrival` removal/deprecation timing | API plan §3 D5 / §7 open input #4; no driver UI exists, so no driver work. |

## Dangling-`depends_on` check

`depends_on` names the **open** API plan `api_plans/[arrival]_proximity_arrival_geofence.md` (present
in the tree) — the reason for the `01_` prefix. No dangling target. The rider sibling is prose
reference, not a `depends_on` entry.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

On an Android host with the API geofence enabled (`GEOFENCE_ENABLED` on): accept a ride, drive to
within 80 m of the pickup with the driver app publishing location, and confirm the trip advances to
`driver_arrived` with no button press and no driver `PUT /status`; repeat the fix and confirm no
second transition. **UNVERIFIABLE in this WSL tree.**
