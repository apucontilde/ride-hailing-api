---
tag: multi
depends_on: []
status: open
---

# Multi-stop + change-destination

Net-new feature. Today a ride is a single pickup→dropoff pair, and the
"change destination" endpoint is a stub that returns success without mutating
anything. This plan makes waypoints a first-class part of the ride model and
wires the change-destination endpoint end-to-end. API-first; the rider app
surface is the `rider-planner`'s to fold, noted below as a cross-app dependency.

## Current state (all cited from code)

- `PUT /rides/:id/destination` is a **stub** — `internal/handler/platform.go:386-388`
  (`UpdateDestination`) returns `{"message":"destination updated"}` and never mutates
  state. Routed at `internal/router/router.go:181`.
- The ride model is scalars, no waypoints — `internal/model/ride.go:10-15`
  (`PickupLat/Lng`, `DropoffLat/Lng`, `PickupAddress`, `DropoffAddress`). Migration
  `005_create_rides.up.sql:11-14` matches: flat `DOUBLE PRECISION` columns.
- The ride state machine has no stop/destination concept —
  `internal/service/ride.go:25-32` (`validTransitions`) maps status→status only.
- Request DTO is flat scalars — `internal/handler/ride.go:29-37` (`rideRequest`).
- Rider app holds two `Place?` fields — `rider_app/lib/features/home/presentation/home_screen.dart:23-24`
  (`_pickupLocation`, `_destination`).
- Known as US-8 in `USER_STORIES.md`; currently documented as a stub.

## Scope

1. **DB + model** — append-only migration introducing a waypoints/stops table
   (ride-scoped, ordered, with an optional `type`/`kind` for stop vs. destination)
   and model fields. `rides` retains its pickup/dropoff scalars as the *final*
   destination for backward compatibility; waypoints are the intermediate stops.
2. **Request/response DTO** — add an ordered `stops` array to the ride request DTO
   and a stops representation on ride responses; validate ordering and non-emptiness.
3. **Service state handling** — extend the ride model/service to carry stops without
   disturbing the existing `validTransitions` status machine; a destination change
   mid-ride is a data mutation, not a state transition.
4. **Change-destination endpoint** — implement `UpdateDestination` to actually
   mutate the ride (re-route / update dropoff / persist), with correct error
   semantics per the domain invariants (write failure → 5xx, never 4xx; a cause is
   logged).
5. **Cross-app note** — the rider app's two-`Place` UI (`home_screen.dart:23-24`)
   needs a stop-list surface; that work belongs to `rider-planner`. This plan stops
   at the API contract; it only *defines* the shape the rider fold-out consumes.

## Invariants carried in

- Migrations append-only; version = numeric prefix; only `*.up.sql` executes.
- Success paths/status codes for *valid* existing requests never change.
- A failed write never answers success; a cause is logged.
- Route cost stays **meters**; stop/waypoint routing reuses the frozen
  `NavigationRepository.GetShortestPath` contract.