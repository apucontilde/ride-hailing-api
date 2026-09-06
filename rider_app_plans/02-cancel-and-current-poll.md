# 02 — LC-1 real cancel + LC-2 current-ride poll

Replace the fake cancel with a real API call, and add `GET /rides/current` polling so "no driver available" and app-restart-restores actually work.

**Read first:** plan `01-ws-contract.md`, `rider_app/lib/features/home/data/home_provider.dart`, `rider_app/lib/features/home/presentation/active_ride_screen.dart`, `rider_app/lib/features/home/presentation/driver_matching_screen.dart`.

## Endpoints (both real)

```http
POST /api/v1/rides/{id}/cancel        # no body → 200 {ride:{status:"cancelled"}}
GET  /api/v1/rides/current            # → 200 {ride: <Ride>|null}
```
Order of routes matters: `/rides/history` and `/rides/current` are static paths; `{id}` is `/rides/:id`. Cancel returns a `ride.updated` WS event (`status:"cancelled"`, `cancelled_by`) that plan 01 now picks up — but the HTTP path must also navigate to home for the mock-replacement case.

Ride object fields available (`handler/ride.go` + `model/ride.go`): `id, status, pickup_lat/lng/address, dropoff_lat/lng/address, vehicle_type, base_fare, distance_fare, time_fare, surge_multiplier, total_fare, requested_at, accepted_at, driver_arrived_at, started_at, completed_at, cancelled_at`.

## LC-1 — real cancel

1. `home_provider.dart`: add `Future<void> cancelRide(String rideId)` → `POST ApiEndpoints.cancelRide(id)`; map `ApiException.ride_active` etc. via `mapStatusCodeToException` (see `core/api/api_exceptions.dart`). Expose as `FutureProvider.family` or a method on the existing notifier.
2. `active_ride_screen.dart`: replace `_cancelRide` (1s mock at line 44) with a confirm dialog + `cancelRide()` call; on success (or on WS `RideStatus.cancelled`) → `context.go('/home')` + toast.
3. `driver_matching_screen.dart`: add a "Cancel request" action that calls `cancelRide()` during `pending` (allowed by the backend state machine) and re-routes to `/home`; guard against double-tap.

## LC-2 — current-ride poll

4. New `current_ride_provider.dart` (or extend `ride_status_provider.dart`): a timer-based poll every **5 s** while state is `matching`:
   - `GET /rides/current` → if `ride != null && status == "no_driver_available"` → set matching-screen state to "no drivers found" + toast (WS never pushes this).
   - If `ride != null && status in (accepted, driver_arrived, in_progress, completed)` and the app just started → restore directly into the active-ride flow.
   - If `ride == null` while `matching` for `> 30 s` → show "still searching" UX (backend dispatch can legitimately run up to `5 radii × 30 s`).
5. Stop the poll on `completed`/`cancelled`/`idle` and on dispose; restart on entering matching.
6. Cold-start restore: in splash/`main.dart` gate, call `GET /rides/current` once before routing.

## Tests

- `home_provider_test.dart` (extend): cancel success + error (401/409).
- New `driver_matching_screen_test.dart` cases: cancel button hits the endpoint (mock adapter asserts path/method); "no drivers" state appears when poll returns `status:"no_driver_available"`.
- `active_ride_screen_test.dart`: pressed cancel → POST sent (no 1s fake), WS `cancelled` event routes home.
- Poll test without real timers: drive `Timer` with an injectable clock or call the poll tick directly.

## Verify

```bash
cd rider_app && flutter analyze && flutter test
```

## Acceptance

- No `Timer(Duration(seconds: 1)` mock remains in `active_ride_screen.dart`.
- Cancel works with no driver online (ride is `pending`), and matching screen returns to home.
- App restart during an active ride resumes the active screen instead of home.