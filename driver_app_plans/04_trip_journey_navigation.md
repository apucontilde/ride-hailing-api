# Plan 04 — Trip journey + navigation (US-D7, D8, D9, US-11)

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
  `{"polyline":[{"lat":..,"lng":..},...],"total_distance_m":..,"total_duration_s":..}`.
  Polyline endpoints are pinned to pickup/dropoff; distance is road-following;
  duration = distance / 11 m/s. No route → 500, app must fall back to a straight
  line (visible dashed overlay). Road graph is cached in-process — restart the API
  after `make import-osm` or results go stale.
- **Boundary logic (build once, reuse):** origin == current trip pickup while
  status `accepted`/`driver_arrived`; origin == rider's latest live location data
  (plan 01 `driver.location`/plan 02 pings) while `in_progress`. Re-request the
  route when the rider has moved >200 m since the last fetch (avoid spamming).

## Work

1. `lib/features/trip/providers/trip_notifier.dart` (new):
   - Reads `rideStateProvider`, exposes `stage`: `pre` (accepted), `enrouteToPickup`
     (`driver_arrived`), `driving` (`in_progress`), `post` (completed), `cancelled`.
   - `advance()` performs `PUT /driver/rides/:id/status` for the next legal status
     and optimistically updates (server `ride.updated` confirms).
   - `cancelTrip(String reason)` → `POST cancel`, optimistic `cancelled`.
   - `route` cache: `(fromKey,toKey)` → `({polyline, distance, duration})` with
     refetch when pickup/`to` changes or target moves >200 m.
2. `lib/features/trip/presentation/trip_screen.dart` (new):
   - `FlutterMap` (`flutter_map` 7 + `latlong2`, already deps): polyline from the
     route, markers for pickup/dropoff, dashed straight-line fallback on 500.
   - **Single primary button** by stage:
     - `pre` → "Accept Trip" (ties into plan 03 accept; only reachable if the
       offer flow went async) / hidden if already accepted.
     - `enrouteToPickup` → "Arrived" → `PUT status: driver_arrived`.
     - `driving` → "Complete Trip" → `PUT status: completed` (confirmation
       dialog), then post-screen.
     - Cancelled (any change) → full-screen "Trip cancelled (by …)" with the
       `cancelled_by` value from the event, button back to home.
   - Fare summary card visible during `post` (from completed event's `fare`).
   - Driver-cancel button (`cancelTrip`) visible only pre-`in_progress`; in
     `in_progress`, show "Rider can cancel" instead of the button.
   - Live rider location pin from `driver.location` events while driving.
3. Navigation refetch hook: a 200 m movement threshold on the live rider position
   triggers route re-request (idempotent, debounced).

## Tests

- `test/features/trip/providers/trip_notifier_test.dart`: stage transitions from
  server events; `advance()` calls the right status endpoint; illegal transitions
  rejected; cancelled-by-rider surfaces `cancelled_by`; route cache + >200 m
  refetch.
- `test/features/trip/presentation/trip_screen_test.dart`: button label + action
  per stage; fallback dashed line rendered when route returns 500; confirmation
  dialog before complete.
- `test/core/ride/ride_state_notifier_test.dart`: `ride.updated` with `completed`
  keeps `fare` on the current ride.

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