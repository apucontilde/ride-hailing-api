# Plan 04 — Trip journey + navigation (US-D7, D8, D9, US-11)

> **Status: ✅ LANDED** (re-audited 2026-09-25). The trip is reachable and
> drivable end to end: `home_screen.dart` pushes `/trip` whenever a ride is held
> (and restores one from `GET /driver/rides/current` on launch, since the WS has
> no replay), `trip_screen.dart` calls `fetchRoute` on mount and on every
> >200 m driver move, the Cancel button opens a confirm dialog wired to
> `cancelTrip()`, and terminal stages clear the held ride and go home. Tests:
> `trip_notifier_test.dart` (30), `trip_screen_test.dart` (11),
> `home_screen_test.dart` (5), plus `ride_state_notifier_test.dart` /
> `location_service_test.dart` / `rides_repository_test.dart` additions — all green.
> **Three real bugs fixed on the way, all found by the re-audit:**
> 1. **Stage collapse.** The old `TripStage` merged `accepted` and `driver_arrived`
>    into one `enrouteToPickup`, so the first button press sent `in_progress` from
>    `accepted` and the server answered **400** (`internal/service/ride.go`
>    `validTransitions`). A distinct `TripStage.arrived` now mirrors the server
>    table 1:1.
> 2. **`ride.updated` parsed as a `Ride`.** The wire shape is
>    `internal/websocket.RideUpdateData` — `ride_id` (not `id`) with **nested**
>    `pickup`/`dropoff`/`fare`, patch-style. Parsing it as a flat `model.Ride`
>    left the held ride with `id == ''`, null coordinates and a null fare. The new
>    `core/ride/ride_update.dart` parses the patch and `applyTo()`s it onto the
>    ride already held, so a status-only broadcast keeps the places and a
>    `completed` one stores the fare.
> 3. **`ref.listen` misses pre-existing state.** `TripNotifier`'s constructor
>    registered a listener but never seeded from the ride already held — and the
>    screen is opened *because* a ride is held, so the trip rendered empty. It
>    now seeds once in the constructor.
> **Deliberately not implemented:** the plan's "origin = rider's live location
> while `in_progress`" is impossible — the server only forwards
> `driver.location` to the **rider**, so the driver app has no rider feed (and no
> live rider pin). The route origin is therefore always the driver's own GPS fix
> (`lastPositionProvider`), which is the useful thing to draw anyway. Turn-by-turn
> guidance is also still open: the map draws the polyline, not a nav session.
> **Still open:** the post-trip rating prompt is plan 05's surface.

Post-accept: route to pickup, arrive, start trip, navigate to dropoff, complete.
One single primary button per trip stage, a flutter_map trip screen with the
backend-routing polyline, and clean handling when the rider (or driver) cancels.

## Facts (re-audited)

- **Ride state machine (server-enforced):** `accepted → driver_arrived →
  in_progress → completed`; `cancelled` reachable from `pending|accepted|
  driver_arrived` (`internal/handler/ride.go`; driver.cancel.go). Advance with
  `PUT /driver/rides/:id/status` body `{"status":"driver_arrived"|"in_progress"|
  "completed"}` (422 on illegal transition). The server broadcasts `ride.updated`
  both to rider and driver (`internal/service/dispatch.go:210-225`), which keeps
  `rideStateProvider.currentRide` fresh.
- **Cancel:** `POST /driver/rides/:id/cancel` (driver-initiated, allowed only
  before `in_progress`; body optional `reason`) — after `in_progress` the driver
  cannot cancel; the rider can (any time → `POST /driver/rides/:id` is not
  involved; the app just reacts to the `ride.updated` `cancelled` event).
- **Navigation route:** `GET /api/v1/navigation/route` with mandatory query
  `from_lat, from_lng, to_lat, to_lng` (422 if missing/non-numeric), Bearer auth
  required. Success:
  `{"polyline":[{"lat":..,"lng":..},...],"total_distance_m":..,"total_duration_s":..}`
  plus `"is_estimate": true` when the pins fell outside road coverage (the
  polyline is then the straight haversine line — api_plans/05).
  Polyline endpoints are pinned to pickup/dropoff; distance is road-following;
  duration = distance / 11 m/s. No route → 500, app must fall back to a straight
  line (visible dashed overlay). Road graph is cached in-process — restart the API
  after `make import-osm` or results go stale.
- **Boundary logic — corrected.** This plan originally assumed the driver could
  route *from the rider's* live location. It cannot: `driver.location` is only
  pushed to the **rider**'s channel, so the driver app has no rider feed and
  `rideState.lastLocation` is always null. The route origin is therefore the
  driver's own live GPS fix for every stage, and the target is the pickup until
  `in_progress`, then the dropoff. Re-request when the **driver** has moved
  >200 m from the cached origin.

## Work (as landed)

1. `lib/features/trip/providers/trip_notifier.dart` (new):
   - Reads `rideStateProvider` and exposes one `TripStage` per server status:
     `pre` (`pending`), `enrouteToPickup` (`accepted`), `arrived`
     (`driver_arrived`), `driving` (`in_progress`), `post` (`completed`),
     `cancelled`. The constructor **seeds** from the ride already held —
     `ref.listen` only fires on later changes, so opening `/trip` with a live
     ride would otherwise render the empty state.
   - `advance()` performs `PUT /driver/rides/:id/status` for the next legal status
     and applies the ride in the PUT response through
     `RideStateNotifier.adoptRide` (the server's `ride.updated` confirms the same
     thing on top). Illegal stages are a no-op — no request is sent.
   - `cancelTrip({String? reason})` → `POST cancel`, guarded to the pre-
     `in_progress` stages. The backend binds no body and derives `cancelled_by`
     from the caller's role, so `reason` is forward-compatibility only.
   - `route` cache keyed by **destination** (`toLat,toLng`) plus the origin it was
     fetched from, refetching when the driver moves >200 m (real haversine — the
     old `_approxDistance` was wrong). The origin is the driver, so keying on it
     too would never hit and would grow the map on every GPS fix. Concurrent
     fetches are deduped and a new ride drops the cache.
2. `lib/features/trip/presentation/trip_screen.dart` (new):
   - `FlutterMap` (`flutter_map` 7 + `latlong2`, already deps): the road polyline
     in blue over a straight-line underlay, markers for the two endpoints and the
     driver, dashed overlay when the route fails or comes back `is_estimate`.
     `tripMapTileProvider` is a seam so tests override the tile layer with `null`.
   - **Single primary button** by stage:
     - `pre` → disabled "Accept the offer to start" (the server allows no driver
       transition from `pending`); nothing at all when no ride is held.
     - `enrouteToPickup` → "Arrived at pickup" → `PUT status: driver_arrived`.
     - `arrived` → "Start trip" → `PUT status: in_progress`.
     - `driving` → "Complete Trip" → `PUT status: completed` (confirmation
       dialog), then the receipt.
     - `post`/`cancelled` → "Trip completed" / "Trip cancelled (by …)" from the
       event's `cancelled_by`, fare card, "Back to home".
   - Terminal stages use `PopScope(canPop: false)` and clear the held ride, so a
     back gesture cannot leave a finished trip on the stack.
   - The controls panel puts its descriptive block in a scroll view so a short or
     landscape viewport can never overflow it.
   - The driver-cancel button is visible only on the `canCancel` stages; in
     `in_progress` the screen says "Rider can cancel from here" instead.
3. `lib/features/home/presentation/home_screen.dart`: pushes `/trip` when a ride
   is held (guarded by `_tripPushed` so a pop does not bounce the driver back),
   shows an "Active trip" banner as the way back in, and restores the ride from
   `GET /driver/rides/current` on launch. `core/ride/ride_update.dart` parses the
   broadcast patch; `core/location/location_service.dart` gained
   `lastPositionProvider` + an `onPosition` callback that fires **before** the
   online/throttle gates, since the trip map needs the real fix regardless of
   whether it is pushed to the server.

## Tests (as landed)

- `test/features/trip/providers/trip_notifier_test.dart` (30): stage mapping from
  every server status; the `ride.updated` merge; `advance()` per stage and the
  illegal no-ops; cancel guards; route cache hit, 200 m refetch, destination
  change, concurrent dedupe, estimate flag, failure; `reset()` and cache drop on a
  new ride.
- `test/features/trip/presentation/trip_screen_test.dart` (11): a ride held
  *before* the screen opens; button label + `advance` per stage; the complete
  dialog (dismissed and confirmed); cancel dialog + `POST`; "Rider can cancel"
  while driving; the terminal fare card and cancelled notice, both returning home
  and clearing the ride; the road polyline vs. the dashed fallback and the
  `is_estimate` case.
- `test/features/home/presentation/home_screen_test.dart` (5): push on a held
  ride, launch restore, failed restore, and the banner re-entry without a push
  loop.
- `test/core/ride/ride_state_notifier_test.dart`: the real broadcast shape —
  nested places, status-only merge, `completed` fare, `cancelled_by`, foreign-ride
  and id-less events ignored, `adoptRide`.
- `test/core/location/location_service_test.dart`: every fix is published even when
  the server push is throttled or the driver is offline.
- `test/features/rides/data/rides_repository_test.dart`: `currentRide()` parsing
  the ride and the `null` case.

## Acceptance

- Driver can drive the whole state machine with exactly one primary button.
- Navigation polyline is road-following (fallback straight-line never crashes).
- Cancel paths (rider or driver) always land on a clean screen, never a stale
  trip.

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: booked ride → "Arrived" → "Complete Trip" → both apps show completed;
rider cancels mid-journey → driver sees cancelled screen.