# 01 — WS-1: Realign WS event handling (foundation)

> **Status: ✅ DONE** — implemented in `rider_app/`. `flutter analyze` clean, `flutter test` fully green (98 tests), incl. new `test/features/home/data/ride_status_provider_test.dart`.

Fix the ride-status event contract in the rider app. The app listens for events the backend never sends, so driver-arrival, cancelled, and completion states are broken today.

**Read first:** `rider_app/lib/features/home/data/ride_status_provider.dart`, `rider_app/lib/features/home/model/driver.dart`, `rider_app/lib/core/network/websocket_service.dart`. (Post-refactor: the WS transport + `Ride` model live in `shared/`; the app files are thin re-export shims — see `AGENTS.md` "Core-file re-export convention".)

## Backend contract (authoritative, `internal/websocket/messages.go`)

Rider app receives exactly these event types:

```jsonc
{ "type":"ride.updated", "data": {
  "ride_id":"...", "status":"pending|accepted|driver_arrived|in_progress|completed|cancelled",
  "timestamp":"...", "eta_seconds":300, // real driver→pickup route ETA; 300 only when location/routing unavailable = treat as "unknown"
  "driver": { "id":"...","first_name":"...","photo_url":"...","rating":5.0,
              "vehicle":{"make":"...","model":"...","color":"...","plate_number":"..."},
              "location":{"lat":..,"lng":..,"heading":..} },
  "pickup":{"lat":..,"lng":..,"address":"..."}, "dropoff":{"lat":..,"lng":..,"address":"..."},
  "fare": {"base_fare":..,"distance_fare":..,"time_fare":..,"surge_multiplier":..,"total":..},   // only on completed
  "cancelled_by":"rider" } }                                                                     // only on cancelled
{ "type":"driver.location", "data": { "ride_id":"...","driver_id":"...","lat":..,"lng":..,"heading":..,"speed":.. } }
```

The backend **never** sends: `ride_matched`, `driver_moved`, `ride_arrived`, `ride_completed`. It also **never pushes a `no_driver_available` event** (DB update only, `service/dispatch.go:59,78`) — that detection is the LC-2 poll plan.

## Current bugs (`ride_status_provider.dart`, lines 34-60)

| Listens for | Reality | Fix |
|---|---|---|
| `ride_matched` | never sent | remove branch |
| `driver_moved` | real event is `driver.location` | handle `driver.location` → typed `DriverLocation` |
| `ride_arrived` | real status is `driver_arrived` inside `ride.updated` | map `ride.updated` status `driver_arrived` → new `RideStatus.driverArrived` |
| `ride_completed` | real status is `completed` | delete duplicate branch (keep `ride.updated` `completed`) |
| `accepted` raw map | data has typed `driver{...}` | parse via the **unused** `DriverInfo`/`DriverVehicle`/`DriverLocation` models in `features/home/model/driver.dart` |
| no `cancelled` | backend sends it | add `RideStatus.cancelled` (+ keep `cancelled_by`) |
| no `no_driver_available` | not pushed | leave state as `matching`; LC-2 poll detects it |

Also `ActiveRideScreen` reads invented keys `driver_lat/driver_lng/driver_name/car_model` (`active_ride_screen.dart:68-72,132-133`) — fixed by plan 03, but design the state to expose typed `driver`, `driverLocation`, `fare`, `cancelledBy`.

## Changes

1. `RideStatus` enum (`ride_status_provider.dart:5`): replace with `{ matching, driverApproaching, waitingForDriver, onTrip, completed, cancelled, idle }` (or keep names — pick clear ones matching backend statuses: `pending/accepted/driver_arrived/in_progress/completed/cancelled`).
2. `RideState`: add typed fields `driver`, `driverLocation`, `fare` (reuse `DriverInfo`, `DriverLocation`; add `Fare` model if absent), plus `rideId` and `cancelledBy`.
3. Event handler: switch on `ride.updated` (map status), `driver.location` (typed location, keep status unchanged), ignore everything else. Remove `ride_matched`/`ride_arrived`/`ride_completed`/`driver_moved`.
4. Keep `copyWith`, `reset()`.

## Tests — `test/features/home/data/ride_status_provider_test.dart` (new)

- Feed each backend-shaped event; assert resulting state (status + typed fields).
- Assert the four invented events are ignored (state unchanged).
- Assert `driver.location` updates `driverLocation` without changing status.
- Assert `cancelled` sets status + `cancelled_by`.

## Verify

```bash
cd rider_app && flutter analyze && flutter test
```

## Acceptance

- No references to `ride_matched`/`driver_moved`/`ride_arrived`/`ride_completed` remain in `lib/`.
- `driver.dart` models are consumed (no longer dead code).
- Green on plan 03's screen after this lands unchanged.