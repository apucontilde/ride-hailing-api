# 05 — LC-0 idempotency reuse + GEO-1 rider-location ping + GEO-3 chip

Three small, independent wiring fixes.

**Read first:** `rider_app/lib/features/home/data/home_provider.dart`, `rider_app/lib/features/home/presentation/home_screen.dart`, `rider_app/lib/core/api/endpoints.dart`.

## LC-0 — reuse the idempotency key per booking attempt

Backend `POST /rides` supports `Idempotency-Key` header (`middleware/idempotency.go`). Today `home_provider.dart` creates a new key per call, defeating retry-replay protection.

1. In the create-ride flow, generate **one** key per booking *attempt* (keep in notifier state, e.g. `String? _bookingIdempotencyKey`), reuse it on every retry of that same booking, clear on success or explicit cancel of the attempt.
2. Note: for a repeated key the backend returns the stored status **with an empty body** — retry handling must tolerate an empty response and, if needed, confirm state via `GET /rides/current`.

## GEO-1 — stream rider location while app is active

Backend uses `PUT /geo/rider/location` as the rider-side anchor; app never calls it.

```http
PUT /api/v1/geo/rider/location   # body {lat, lng} → 204 (NO body — don't parse JSON)
```

1. New `location_ping_service.dart` (or extend `home_provider.dart`): subscribe to `geolocator` position stream; on each fix, throttle to **every 5 s** and `PUT` `{lat,lng}`; ignore/`catchError` 4xx.
2. Start when Home or active-trip screen is active; stop on dispose/pause (platform channel `AppLifecycleState`).
3. Make throttle testable: inject a clock/ticker.

## GEO-3 — surface the dead `nearbyDriversProvider`

`features/home/data/home_provider.dart:10` defines `nearbyDriversProvider` (`GET /geo/nearby-drivers`) but nothing consumes it.

1. On `home_screen.dart`, `ref.watch(nearbyDriversProvider)` while the user is configuring a trip; render a small "X drivers nearby" chip.
2. On error leave the chip hidden (silent). Don't claim per-driver ETA (`/geo/eta` duplicates `estimates/eta` — excluded from scope, not a hardcode).

## Tests

- Idempotency: two create attempts in the same booking session send the **same** `Idempotency-Key` header (assert via `http_mock_adapter`); new booking gets a new key.
- GEO-1: injected clock → only 1 request per 5 s; 204 handled; pause stops the stream.
- GEO-3: chip appears with count when provider returns drivers; hidden on error.

## Verify

```bash
cd rider_app && flutter analyze && flutter test
```

## Acceptance

- Retry of a failed booking reuses the key; success clears it.
- Rider position is streamed while the app is open (visible to backend in `driver_positions`-style data / nearby queries).
- `nearbyDriversProvider` is consumed (no longer dead code).