---
tag: ontrip
depends_on: ["landed [trip] journey state machine + [map] shared tile layer (driver_app_plans/STATUS.md)"]
status: open
---

# [ontrip] Trip map shows only the next stop; drawer lists the whole itinerary

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification).

## Goal

On the trip screen, the map shows **only the immediate next waypoint** (and the driver), while the
bottom panel lists **all** stops of the itinerary in visit order. Today the driver trip layer has no
itinerary at all: the map draws pickup + dropoff and the panel shows a single target line.

## Current state (verified)

- The API exposes the itinerary as an **additive sibling** `stops` of `ride`: `GET /driver/rides/:id`
  and `GET /driver/rides/current` return `{ride, stops}`
  (`internal/handler/ride.go:270-282,303-313`). The model is `model.RideStop`
  (`internal/model/ride.go:132-154`): `sequence`, `kind` (`stop` | `destination`), `lat`, `lng`,
  `address`. `stops` excludes the pickup and its last row is the destination, mirroring `dropoff_*`.
- The driver app **drops** it: `RidesRepository.fetchRide` / `currentRide` parse only `data['ride']`
  (`driver_app/lib/features/rides/data/rides_repository.dart:91-98,118-124`). There is no `RideStop`
  model in `shared/` and none in `driver_app` (grep). The rider app has its own local `RideStop`
  (`rider_app/lib/features/home/model/ride_stop.dart`) and a multi-leg router
  (`rider_app/lib/features/home/data/trip_route_provider.dart:56-227`).
- The driver trip map draws pickup + dropoff markers and one route to the stage target
  (`driver_app/lib/features/trip/presentation/trip_screen.dart:283-364`); the bottom panel shows a
  single target line (`:523-526,548`).
- The WS `ride.updated` does **not** carry `stops` (`internal/websocket/messages.go:10-27`: only
  `dropoff`); a destination change replaces only the destination row
  (`internal/service/ride.go:573-579`), so intermediate stops are unchanged and the destination is
  derivable from `ride.dropoff*`.

## Design (app-only)

1. **Driver-local model.** Add `driver_app/lib/features/trip/model/ride_stop.dart`, mirroring the
   rider's (sequence / kind / lat / lng / address, `isDestination`). Do **not** add it to `shared/` in
   this plan; the shared extraction is an optional cross-domain follow-up (see Cross-domain).
2. **Repository.** Add `RideItinerary {Ride ride; List<RideStop> stops;}` plus
   `fetchRideItinerary(id)` / `currentRideItinerary()` that parse the sibling `stops` and sort by
   `sequence`; keep `fetchRide` / `currentRide` (used by the offer sheet and history) parsing only
   `ride`. Degrade to `[]` when the `stops` key is absent.
3. **Trip state.** `TripNotifier` / `TripState` hold the loaded `stops` and derive the ordered
   waypoints `[pickup, ...intermediateStops, destination]`; load them when the ride id is first seen
   (`GET /driver/rides/:id` or `/current`), and update the destination row from `ride.dropoff*` on a
   `ride.updated` destination change (no refetch needed for the unchanged intermediate stops). Clear
   on a new ride id (already done for the route cache, `trip_notifier.dart:151-153`).
4. **Next-waypoint selection** (documented local heuristic — the server has no per-stop completion
   signal):
   - `pre` / `enrouteToPickup` / `arrived` → the **pickup**.
   - `driving` → the first waypoint in `[...intermediateStops, destination]` farther than
     `nextStopArrivalRadiusM` (default ~120 m) from the driver's `lastPositionProvider` fix; the
     destination is always last.
   - No fix → the first intermediate stop (or the destination if there are none).
   - Expose the radius as an overridable provider so tests are deterministic.
5. **Trip screen.**
   - `_targetFor` returns the next waypoint above; `_syncRoute` routes only to it. `_syncRoute` already
     runs on every position update and `_routeCache` is keyed by destination, so crossing a stop
     advances the target and re-fetches automatically.
   - `_MapView` renders only the **next-waypoint** marker plus the driver marker (drop the pickup /
     dropoff markers); icon per kind (pin = pickup, flag = destination, dot = intermediate).
   - The bottom panel (`_StageControls`) becomes the "drawer": list **all** waypoints in order
     (pickup → stops → destination) with the next one marked, scrollable, keyed
     `Key('trip-itinerary')`.
   - Keep the honesty rule: a failed / `is_estimate` route still draws dashed/estimate
     (`trip_screen.dart:304-321`).

## Tests to add/change

- New `driver_app/test/features/trip/model/ride_stop_test.dart` (fromJson, `isDestination`).
- `driver_app/test/features/rides/data/rides_repository_test.dart`: `fetchRideItinerary` parses the
  sibling `stops` (ordered by `sequence`) and degrades to `[]` when absent.
- `driver_app/test/features/trip/providers/trip_notifier_test.dart`: waypoint ordering; next-target
  selection by proximity; a destination change updates the destination row; a new ride id clears
  stops.
- `driver_app/test/features/trip/presentation/trip_screen_test.dart`: the map shows only the next
  marker (not all); the drawer lists every stop; moving the position near an intermediate stop
  advances the next target and re-requests the route to it.

## Cross-domain

- **None required.** The endpoints and the `stops` envelope already exist; the model is app-local.
- **Flag for the cross-app-planner (optional, not a blocker):** `RideStop` is a pure model now
  duplicated between `rider_app` and `driver_app`; extracting it into `shared/lib/src/models/` would
  remove the drift risk. This plan deliberately does **not** edit `shared/`.

## Open inputs

- The "next" heuristic radius (~120 m) and whether the API should expose a per-stop completion signal
  — resolve with product / api-planner; a server signal would replace the proximity heuristic.
- Whether the drawer should visually mark reached vs pending stops — cosmetic.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```
