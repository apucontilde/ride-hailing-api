---
tag: geo
depends_on: []
status: open
---

# Rider location ping + nearby-drivers chip

**Partial** — the idempotency-key reuse (LC-0) from the original plan already landed
(`home_provider.dart:172,188,216-218`, `_attemptKey`); see [STATUS.md](STATUS.md) Landed. What
remains is the two rider-side geo wirings below.

**Read first:** `rider_app/lib/features/home/data/home_provider.dart`,
`rider_app/lib/features/home/presentation/home_screen.dart`,
`rider_app/lib/core/api/endpoints.dart`.

## GEO-1 — stream rider location while app is active

Backend uses `PUT /geo/rider/location` as the rider-side anchor; the app never calls it
(`rider_app/lib` has no `geo/rider` reference).

```http
PUT /api/v1/geo/rider/location   # body {lat, lng} → 204 (NO body — don't parse JSON)
```

1. New `location_ping_service.dart` (or extend `home_provider.dart`): subscribe to the
   `geolocator` position stream; on each fix, throttle to **every 5 s** and `PUT` `{lat,lng}`;
   ignore/`catchError` 4xx.
2. Start when the Home or active-trip screen is active; stop on dispose/pause (platform channel
   `AppLifecycleState`).
3. Make the throttle testable: inject a clock/ticker.

## GEO-3 — surface the dead `nearbyDriversProvider`

`features/home/data/home_provider.dart:12` defines `nearbyDriversProvider`
(`GET /geo/nearby-drivers`) but nothing consumes it (sole reference in `lib/`).

1. On `home_screen.dart`, `ref.watch(nearbyDriversProvider)` while the user is configuring a
   trip; render a small "X drivers nearby" chip.
2. On error leave the chip hidden (silent). Don't claim per-driver ETA (`/geo/eta` duplicates
   `estimates/eta` — excluded from scope, not a hardcode).

## Tests

- GEO-1: injected clock → only 1 request per 5 s; 204 handled; pause stops the stream.
- GEO-3: chip appears with count when provider returns drivers; hidden on error.

## Verify

```bash
make flutter-analyze
make flutter-test
```

## Acceptance

- Rider position is streamed while the app is open (visible to backend in `driver_positions`-style
  data / nearby queries).
- `nearbyDriversProvider` is consumed (no longer dead code).
