# Plan 02 — Online/offline + live location loop (US-D4)

> **Status: ✅ LANDED** (re-audited 2026-09-25). `AvailabilityNotifier` flips
> `PUT /driver/me/status` with a double-tap guard that reverts the switch if the
> call fails, and `syncFromProfile` keeps it truthful after a profile refresh.
> `LocationService` streams geolocator fixes, pushes
> `PUT /geo/driver/location` at ≥5 s intervals only while online, and buffers
> failures in a bounded 60-point batch flushed to
> `PUT /geo/driver/location/batch`. `home_screen.dart` renders the toggle, the
> status chip, the permission banner and the offer trigger. Tests:
> `availability_notifier_test.dart` + `location_service_test.dart`.
> **Added by plan 04:** `lastPositionProvider` + an `onPosition` callback that
> fires for **every** fix, before the online/throttle gates — the trip map and
> the route refetch need the driver's real position whether or not it is pushed
> to the server.
> **Still open:** `appPermissionProvider` is never written by
> `requestPermission()`, so the "permission denied" banner can never fire;
> `app.dart`'s two authenticated branches are redundant.

> **⚠️ Fixed 2026-09-26 — going online did not publish a position.** This was
> the second, independent cause of "the driver never receives a ride offer" and
> the one the browser suite caught. `LocationService._onPosition` discards
> fixes while offline, and geolocator only re-emits on movement, so a driver
> who toggled online while stationary could hold **no** `driver_positions` row
> at all. Dispatch only considers a driver whose last position is younger than
> 30 s (`internal/repository/geo_repo.go:73`), so such a driver was invisible
> indefinitely: online, watching the app, never offered a ride, nothing on
> screen to say why. `LocationService` now remembers the last fix and gained
> `publishLastPosition()`, which pushes it immediately and bypasses the
> throttle; `home_screen.dart` calls it whenever the switch goes on. The
> throttle exists to spare the *routine* ping stream, not to delay the first
> row dispatch can see. Covered by three cases in `location_service_test.dart`
> and end-to-end by `e2e/specs/ride-offer.spec.ts`, which polls
> `GET /drivers/:id/location` for the row instead of sleeping a guessed
> interval.

The heartbeat of the driver app: a single availability switch that flips the
driver's server status and starts/stops a throttled GPS ping so the dispatcher can
find the driver. Everything else (offers, trips) depends on this.

## Facts (re-audited)

- **Status:** `PUT /driver/me/status` body `{"status":"online"|"offline"}`
  (`internal/handler/driver.go:105-117`). Returns the updated driver profile.
  In dispatch, only `online` drivers are offered rides (radius
  `{500..10000}m`, max 5, score-ordered — `internal/service/dispatch.go:45-48`).
- **Location:** `PUT /geo/driver/location` body
  `{"lat":..,"lng":..,"heading":..,"speed":..}` — all numbers, `lat/lng` validated
  `[-90,90]/[-180,180]`, 422 on out-of-range (`internal/handler/geo.go:42-...`).
  Batch variant `PUT /geo/driver/location/batch` body `{"points":[{lat,lng,heading,
  speed},...]}` (`geo.go:88`) for catch-up after an outage. Response is
  `{"status":"ok"}` / void.
- **WS tie-in:** drivers must keep `/ws` live to receive offers
  (`dispatch.go:97`). The ping message keeps the proxy from dropping the socket.
- The location update is **only** the driver's own position; there is no
  "driver location" GET to worry about for this loop.

## Work

1. `lib/features/home/providers/availability_notifier.dart` (new):
   - `availabilityProvider` (StateNotifier):
     - `online` (bool) — mirrors server profile `status`.
     - `toggle()`: `PUT /driver/me/status`; on success flip state; on 422/network
       failure revert + surface error. Guard against double-taps.
     - `setOnline/setOffline` invoked by the WS-driven profile sync.
2. `lib/core/location/location_service.dart` (new, mirroring `rider_app`'s
   `core/location` patterns):
   - Wraps `Geolocator`: continuous `Stream<Position>`, always-on permission
     request, `AppPermission` state exposed as a provider.
   - Throttle to **≥5 s** between pings and only push **when online** (silently
     ignore locations while offline; cancel the subscription on sign-out so the OS
     doesn't keep a background callback).
   - On push failure, buffer the last point and flush it as a batch on next
     success (uses `batch` variant) — bounded to 60 points.
3. `lib/features/home/presentation/home_screen.dart` (rework the placeholder):
   - AppBar with avatar + status dot; main switch
     `Switch(value: online, onChanged: availabilityProvider.toggle)` with a
     clear "You're online — offers will appear here" empty state when online and
     no offers yet.
   - Show live `status` from `driverProfileProvider`. Display a permanent banner
     when `openGeoLocationPermission` is denied.
   - Small live location tile (lat/lng + heading + last push time) for dev
     verification; removable later.
4. Lifecycle hooks in `app.dart`/`main.dart`: on app start if profile status is
   `online` (crashed-while-online recovery) the location stream re-arms without
   flipping the switch; on `logout()` everything stops.

## Tests

- `test/features/home/providers/availability_notifier_test.dart`:
  `toggle()` calls `PUT /driver/me/status` and flips state; failure reverts and
  surfaces error; double-tap is ignored while in flight.
- `test/core/location/location_service_test.dart`: throttles to ≥5 s; skips pushes
  while offline; buffers + flushes a batch after a failed push; stops subscription
  on dispose.
- Widget: home switch reflects `online`, tap calls `toggle()` (mocktail + fake
  notifier via providers).

## Acceptance

- Going online makes the server see `status: online` and the dispatcher can find
  the driver (verify with the rider app nearby-by search or `GET /geo/nearby-drivers`).
- Going offline stops location pings and no offers arrive.
- No location updates are sent while offline (throttle test proves it).

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: dashboard → go online → move around → rider app "request ride" finds you;
go offline → rider request shows no drivers.

The "go online" half of that walkthrough is now automated too — and is exactly
the half that used to require you to physically move first:

```bash
cd e2e && npm install && npm run build:apps && npm test
```