---
tag: ontrip
depends_on: ["landed [trip] journey state machine + [ws] ride.updated patch merge (driver_app_plans/STATUS.md)"]
status: open
---

# [ontrip] Live destination change reaches the trip route + map

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification).

## Goal

When the rider changes the destination, the API already pushes a `ride.updated` to the assigned
driver. The driver app must consume it: move the destination marker, re-request the road route to the
new destination, and re-fit the camera — without waiting for the next GPS fix.

## API half is already landed (do not re-plan, do not edit `api_plans/`)

- `internal/service/ride.go:561-606` `ChangeDestination` writes the new destination and fans out a
  `ride.updated` to **both** rider and driver (`:600-602`), carrying `Dropoff *PlaceInfo` (`:593-597`)
  with the status echoed unchanged (a data mutation, not a transition).
- Driver parse path exists: `driver_app/lib/core/network/ws_event.dart:15` maps `ride.updated`;
  `RideUpdate.fromJson` reads the nested `dropoff` (`driver_app/lib/core/ride/ride_update.dart:67-69`)
  and `applyTo` merges it onto the held ride (`:91-93`); `RideStateNotifier._onRideUpdated` patches
  `currentRide` (`driver_app/lib/core/ride/ride_state_notifier.dart:81-101`).

## The gap (verified)

- `TripNotifier._syncFromRideState` copies the new ride into `TripState` on every `rideStateProvider`
  change (`driver_app/lib/features/trip/providers/trip_notifier.dart:141-160`), so the map's dropoff
  **marker** moves immediately (`trip_screen.dart:213,285-286,353-357`) and `_targetFor` returns the
  new dropoff during `driving` (`:66-70`).
- But `TripScreen` refetches the route only when the **stage** changes or the **position** changes
  (`trip_screen.dart:179-184`), and `_fitTo`'s key is `${stage.name}:${route?.fetchedAt}` (`:332`). A
  destination-only `ride.updated` keeps the stage, so the **polyline stays the old destination's
  route** and the camera does not refit until the next GPS fix — indefinitely if the driver is
  stationary (geolocator does not re-emit while stationary; see `home_screen.dart:218-225`). The
  screen can therefore show a route to the old destination while the flag is at the new one.

## Scope (app-only)

- In `TripScreen`, extend the `tripNotifierProvider` listener (`:182-184`) to also call `_syncRoute()`
  when the held ride's destination (`dropoffLat`/`dropoffLng`) changes, and make the fit key include
  the destination (or reset `_fittedKey`) so the camera re-fits to the new target.
- No cache change needed: `_routeCache` is already keyed by destination (`trip_notifier.dart:116,227`),
  so a new destination is a cache miss and re-fetches.
- The drawer target text already uses `ride.dropoffAddress` (`trip_screen.dart:523-526,548`), so it
  updates on rebuild.
- Optional same-class fix: also trigger on a changed pickup (`pickupLat/pickupLng`).
- **Coordination with `[ontrip]_itinerary_next_stop.md`:** if that plan lands first, `_targetFor`
  becomes "next waypoint"; keep this trigger keyed on the ride's destination so it survives that
  refactor. The two plans touch the same `_syncRoute`/fit-key area — land them in either order but
  re-run this suite after both.

## Tests to add/change

- `driver_app/test/features/trip/presentation/trip_screen_test.dart`: broadcast `in_progress` with
  places, then broadcast `in_progress` again with a **different** dropoff; assert a second
  `GET /navigation/route` is made with `to_lat`/`to_lng` equal to the new dropoff and the dropoff
  marker moved. Extend `driver_app/test/support/trip_fixtures.dart` `rideUpdated(...)` with optional
  dropoff/pickup overrides.
- `driver_app/test/features/trip/providers/trip_notifier_test.dart`: a destination-only patch
  updates `currentRide.dropoffLat/lng` and leaves the stage unchanged (regression guard for the
  merge).

## Cross-domain

- None. The API fan-out is landed; this is a driver-consumption plan. **If a gap is ever found in the
  API's `ride.updated` payload, report it to the cross-app-planner — do not edit `api_plans/`.**

## Open inputs

- Should the route also re-fit when only the pickup changes (rare)? Recommended: yes, same trigger.
- None blocking.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```
