---
tag: arrival
depends_on:
  - "api_plans/[arrival]_proximity_arrival_geofence.md"
status: open
---

# 01 [arrival] Auto-arrival + "driver is nearby" notice (rider consumption)

> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> Verification). **Numbered `01_`** because `depends_on` names an **open** plan —
> `api_plans/[arrival]_proximity_arrival_geofence.md` (the unnumbered `[arrival]` chain head). This is
> the rider stage of the `arrival` chain. **Nothing here is claimed landed.**
>
> **Canonical ownership: the API owns the geofence, the nearby flag and the state transition.** This
> rider plan **only consumes** them and must never invent "near" or "arrived". If the API plan's
> shapes change, this plan is re-synced **before** either lands — the fields and semantics below are
> adopted **verbatim** from `api_plans/[arrival]_proximity_arrival_geofence.md` §2.

## Request

> the rider is notified when the driver is NEARBY and when the driver ARRIVES, and the trip state
> advances automatically.

## Canonical contract (adopted verbatim from the API plan)

### Nearby — additive `driver.location` fields

`internal/websocket/messages.go` → `DriverLocationData` gains (API plan §2.4):

```go
NearPickup        bool    `json:"near_pickup,omitempty"`
DistanceToPickupM float64 `json:"distance_to_pickup_m,omitempty"`
```

Semantics (verbatim):

- `distance_to_pickup_m` = **straight-line (haversine) metres** from the fix to the ride's pickup;
  present while the caller's active ride is `accepted` (omitted when `0`).
- `near_pickup` = `true` once the fix crosses `d ≤ 300 m`, stays `true` until `d > 330 m`
  (30 m hysteresis), then clears/re-arms. Omitted while `false`.
- The fields are **omitted (legacy payload)** when there is no `accepted` active ride for the caller.
- **Nearby never changes `ride.status`** — `status` stays `accepted` until the arrive gate.

### Arrival — a server-emitted `ride.updated`

Arrival is a `ride.updated` broadcast **the server emits automatically** when the arrive gate fires
(API plan §2.3):

```json
{"type":"ride.updated","data":{"ride_id":"<id>","status":"driver_arrived","timestamp":"<RFC3339>"}}
```

It is sent to **both** rider and driver; the manual `PUT /:id/status` remains an override, not the
normal path. The rider does **not** set this state itself.

### Backgrounded rider push (context, not the shipped foreground path)

The API fires a `ride.nearby` push once per crossing for a backgrounded rider (API plan §2.4). The
rider's device-token seam is landed but delivery is **inert** in this workspace (no FCM/APNs provider,
`NoopPushTokenSource` — STATUS.md → Landed `[push]`), so the **foreground WS `driver.location`** is
the delivered signal for this plan. Push-data handling is an open input (see below), not a
requirement now.

## Rider work

1. **Parse the fields** in `DriverLocation.fromJson` —
   `rider_app/lib/features/home/model/driver.dart:86-109`. Additive:
   - `nearPickup: json['near_pickup'] as bool? ?? false` (absent ⇒ `false`);
   - `distanceToPickupM: (json['distance_to_pickup_m'] as num?)?.toDouble()` — **nullable**; because
     Go `omitempty` also drops a genuine `0.0`, `null` means "unknown", never `0 m`.
2. **Thread them through state** in the `driver.location` handler —
   `rider_app/lib/features/home/data/ride_status_provider.dart:122-128`
   (`_handleDriverLocation` → `DriverLocation.fromJson`). Add additive `RideState` fields
   (`nearPickup`, `nearPickupDistanceM`) with `copyWith` (`:10-52`) so the screen watches one source.
3. **Clear on transition.** When a `ride.updated` moves the status off `driverApproaching`
   (`_handleRideUpdated` `:80-110`), reset `nearPickup = false` / distance `null` so a stale "nearby"
   flag cannot survive arrival or trip start. (The server hysteresis handles the within-`accepted`
   flicker; the client handles the status change.)
4. **Surface the "driver is nearby" notice** on `ActiveRideScreen`
   (`rider_app/lib/features/home/presentation/active_ride_screen.dart`), rendered only when
   `status == RideStatus.driverApproaching && nearPickup`. Insert near the existing status chip / ETA
   row in `_buildDriverInfoSheet` (chip `:711`, ETA row `:715-728`). Optional distance line
   (`{m} m away` / `{km} km away`) when `nearPickupDistanceM != null`.
5. **Reflect auto-arrival.** Nothing new to build: `_handleRideUpdated` already maps
   `driver_arrived` → `RideStatus.driverArrived` (`:164-165`) and the screen's status listener
   (`active_ride_screen.dart:474-492`) reacts; the restore/poll path (`GET /rides/current` returns
   `driver_arrived`) also converges through `updateFromCurrentRide` (`:115-120`). The nearby notice
   simply disappears and the arrived surfaces take over.

## Reference (do NOT redefine here)

- **Arrived CHIP wording** (`RideStatus.driverArrived` label) is owned by
  `rider_app_plans/[ontrip]_status_labels.md` (it also owns Known bug #29, the generic `Matching`
  fallback).
- **ETA-row arrived semantics** (`driverArrived` shows an arrived state / no countdown; `onTrip` shows
  no arrival countdown) are owned by `rider_app_plans/[ontrip]_driver_arrival_eta.md` (D1 there).

This plan adds the **pre-arrival nearby notice only**. It must not add a second arrived label or a
second ETA row — coordinate the three surfaces so they agree.

## Boundaries

- **Rider-only, app-local.** Consumes `driver.location` (foreground WS). **No API change** (the API
  plan owns the geofence/fields/transition), **no `shared/` change** (no new symbol/shim), **no driver
  change** (the driver publishes fixes already).
- **Never invent near/arrived.** If `near_pickup` is absent/false, no notice. If no `ride.updated
  {driver_arrived}` was received, the rider never renders arrived from a distance it computed itself.

## Tests (new / changed)

| Test | File | Asserts |
| --- | --- | --- |
| Parse + absent defaults | `rider_app/test/features/home/data/ride_status_provider_test.dart` (extend) | a `driver.location` with `near_pickup:true`/`distance_to_pickup_m` sets the state; an absent pair ⇒ `nearPickup=false`, distance `null` (never `0`). |
| Clear on transition | same file | after a `near_pickup:true` fix, a `ride.updated {status:"driver_arrived"}` resets `nearPickup=false`; a later `driver.location` with the fields omitted also clears it. |
| Nearby notice | `rider_app/test/features/home/presentation/active_ride_screen_test.dart` (extend) | `driverApproaching` + `near_pickup:true` renders the notice (and optional distance); `near_pickup:false` renders none; `driverArrived`/`onTrip` render none. |
| No sibling redefinition | same file | the notice does not alter the `trip-eta` row or the status chip — the sibling plans own those (assert the chip/ETA behavior is unchanged by this batch). |

Existing tests that must stay green (not deleted):
`rider_app/test/features/home/data/driver_tracking_provider_test.dart` (the `driver.location`
transport is untouched), `active_ride_screen_test.dart` ETA/chip cases.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` must be clean; `melos run test` green across rider / driver / shared.
- **UNVERIFIABLE in this WSL harness:** the real geofence crossing and auto-advance on a device. Close
  on an Android host against the API plan's on-host steps: with an `accepted` ride, publish a driver
  fix at ~250 m (expect the nearby notice, no state change) then ≤80 m (expect the auto
  `driver_arrived`, the notice clearing and the arrived surfaces taking over), and repeat at ≤80 m
  (expect no second arrival).
- `make flutter-analyze` / `make flutter-test` are **broken from this WSL tree** — do not use them.

## Open inputs / unknowns

1. **Notice form:** inline banner/card in the driver sheet (recommended) vs a transient snackbar vs a
   map overlay. Confirm dismissal behavior (recommended: non-dismissible, clears on arrival).
2. **Distance display:** show `nearPickupDistanceM` (recommended, when non-null) and its exact format;
   never render the omitted-`0` as a real "0 m".
3. **Backgrounded push handling:** deferred — the push delivery is inert until a real FCM/APNs source
   replaces `NoopPushTokenSource` (Landed `[push]`). Re-open when push is wired.
4. **API thresholds (300/330/80):** product values owned by the API plan; the rider consumes whatever
   the server flags. No rider-side threshold.

## Invariants touched (from STATUS.md)

- The status set stays consistent with `_statusFromBackend` (`ride_status_provider.dart:158-177`); no
  new enum value is introduced — arrival is the existing `driverArrived`.
- The active trip never draws a confident road-less route, and an unknown ETA is never rendered
  (`[ontrip]` invariants) — this plan adds a point/proximity notice only.
- Keep the re-export-shim structure intact; add **no** shared symbol / shim.
- Nearby must never lie about status: the notice is advisory and only shown while the server holds
  `accepted` and sends `near_pickup:true`.
