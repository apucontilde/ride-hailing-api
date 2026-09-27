---
tag: tracking
depends_on: []
status: open
---

# Ride detail + receipt + rating, live tracking

**Partial** — the typed WS state this builds on (`RideState.driver` / `driverLocation` / `fare`,
backend status mapping) already landed; see [STATUS.md](STATUS.md) Landed → `[tracking]`. What
remains is the two screens' consumption of it: LC-3 (detail/receipt/rating) and LC-4 (live
tracking) below.

**Read first:** `rider_app/lib/features/home/presentation/active_ride_screen.dart`,
`rider_app/lib/features/home/data/ride_status_provider.dart`,
`rider_app/lib/features/home/data/home_provider.dart`.

## Endpoints (all real)

```http
GET  /api/v1/rides/{id}                 # → 200 {ride: {...}}            (ride object, all fare/timestamps)
GET  /api/v1/rides/{id}/receipt         # → 200 {receipt: {base_fare, distance_fare, time_fare, surge_multiplier, total}}
POST /api/v1/rides/{id}/rate            # body {score: 1..5, comment} → 200 {message:"rating submitted"}
GET  /api/v1/drivers/{id}/location      # → 200 {lat, lng, heading, speed, ...}   (polling fallback)
```
Backend gaps to tolerate: rating has **no** `completed`/party check (don't harden beyond a
disable-on-tap guard); `eta_seconds` in the accept payload is a real driver→pickup route ETA that
falls back to `300` when driver location/routing is unavailable — treat `300` as "unknown" and
compute distance client-side via `core/utils/location_helper.dart`, otherwise trust it; accept
payload `driver.rating` parses to `0.0` (display fallback "New").

## LC-3 — detail, receipt, rating

1. New `features/home/data/ride_provider.dart` with `fetchRide(id)`, `fetchReceipt(id)`,
   `rateRide(id, score, comment)` (wire `rideById`, `receipt`, `rateRide` from `endpoints.dart`).
2. On entering the active trip: resolve `rideId` (from WS `ride_id` or the current-ride poll),
   call `GET /rides/:id` for authoritative state, merge into `RideState`.
3. On WS `completed` (or receipt tap on the summary screen): show a fare-breakdown dialog from
   the WS `fare` payload or `GET /rides/:id/receipt`.
4. On `completed` → after the receipt dialog, offer a 1–5 star rating (submit
   `POST /rides/:id/rate`; disable double-submit; swallow "already rated" gracefully).

## LC-4 — live tracking

5. `ActiveRideScreen`: consume `RideState.driver` (name, photo, rating, vehicle) and
   `driverLocation` (update marker + re-center) — replace invented keys
   `driver_lat/driver_lng/driver_name/car_model` (`active_ride_screen.dart:109,173-174`).
6. Polling fallback in `ride_provider.dart` or a new `driver_tracking_provider`: every **5 s**
   call `GET /drivers/:id/location` when no `driver.location` WS event arrived for **10 s** (use
   the driver `id` from the accepted payload). Stop all timers on dispose/`completed`/`cancelled`.

## Tests

- `ride_provider_test.dart`: parse ride/receipt from mock JSON; rate success + double-submit guard.
- `active_ride_screen_test.dart`: renders typed driver name/vehicle from state; marker moves when
  `driverLocation` updates; fare dialog shows receipt numbers.
- Tracking: injected WS `driver.location` skips HTTP poll (advance clock); silence triggers
  `GET /drivers/:id/location`.

## Verify

```bash
make flutter-analyze
make flutter-test
```

## Acceptance

- `active_ride_screen.dart` has no `driver_lat`/`driver_name`/`car_model` string reads.
- Live driver marker updates during a real trip; falls back to HTTP when WS is silent.
- Completion shows a real receipt and a rating prompt.
