# Plan — Wire unused backend API features into `rider_app`

Audited against: backend at `051ecaf` (see `USER_STORIES.md` v2 for the authoritative endpoint status matrix) and `rider_app` (HEAD Flutter app).

**Goal:** make the Flutter rider app actually consume the backend features it declares but never calls, and fix the places where the app invents/expects WS events the backend never sends. Detailed next to each workstream: files to change, endpoint + payload shape, and how to verify.

---

## 1. Current state — what's already wired

| Backend feature | App usage | Verdict |
|---|---|---|
| `POST /auth/register`, `login`, `logout` | `auth_provider.dart` | ✅ used |
| `POST /auth/refresh` | `auth_provider.dart:138` | ⚠️ defined, **never invoked** (no 401 retry) |
| `GET /rider/me` | `auth_provider.dart:56` (checkAuth) | ✅ used, but profile screen renders static mock |
| `POST /auth/forgot-password` | — | ❌ declared, screen is fake UI |
| `GET /geo/nearby-drivers` | `home_provider.dart:10` | ❌ **dead code** — nothing consumes the provider |
| `GET /estimates/price` | `home_screen.dart:432` | ✅ used (backend prices from region-scoped DB `fare_rates`) |
| `GET /places/autocomplete` | `location_search_screen.dart` | ✅ used |
| `POST /rides` (+ `Idempotency-Key`) | `home_provider.dart:104` | ✅ used, but new key generated per call (see LC-0) |
| `GET /ws` (receive) | `websocket_service.dart` + `ride_status_provider.dart` | ⚠️ connected, but event mapping is broken (see §3) |

Everything else in `endpoints.dart` is **declared-but-never-called**:
`eta`, `currentRide`, `rideById`, `cancelRide`, `rateRide`, `tipRide`, `receipt`, `driverLocation`, `paymentMethods`, `ridesHistory`, `sos`.

And beyond the declared set, the app never calls: `PUT /geo/rider/location`, `PUT /rider/me`, `PUT /rider/me/status`.

---

## 2. Gap matrix (feature → endpoint → current app behavior)

| # | Backend endpoint | Status (backend) | App today | Action |
|---|---|---|---|---|
| LC-0 | `POST /rides` idempotency key | ✅ real (partial) | new key on every attempt defeats retry-replay | reuse the SAME key per booking attempt |
| LC-1 | `POST /rides/:id/cancel` | ✅ real | `ActiveRideScreen._cancelRide` is a **1s mock** (`active_ride_screen.dart:44`) | real call + handle `ride.updated` `cancelled` |
| LC-2 | `GET /rides/current` | ✅ real | unused | poll during driver-matching (see §3) |
| LC-3 | `GET /rides/:id` | ✅ real | unused | fetch authoritative state on active-ride open |
| LC-4 | `GET /rides/:id/receipt` | ✅ real | unused | show fare breakdown on completion |
| LC-5 | `POST /rides/:id/rate` | ✅ real (no completed/party check) | unused | rating dialog after completion |
| LC-6 | `GET /rides/history` | ✅ real | `HistoryScreen` is "No rides yet" static | paginated history list |
| LC-7 | WS `driver.location` + `GET /drivers/:id/location` | ✅ real | app listens for invented `driver_moved`; no polling | real-time + polling fallback |
| GEO-1 | `PUT /geo/rider/location` | ✅ real | **never called** | stream rider position while app is open |
| GEO-2 | `GET /geo/eta` | ✅ real (route-based; equals `estimates/eta` semantics) | declared, unused | SKIP in app (redundant with `estimates/eta`; accept payload already carries driver→pickup ETA, `300` only when location/routing unavailable) |
| GEO-3 | `GET /geo/nearby-drivers` (already wired provider) | ✅ real | dead provider | surface on Home (nearby driver count / ETA hint) |
| AC-1 | `POST /auth/forgot-password` | ✅ real | fake "check your email" UI | real call |
| AC-2 | `GET/PUT /rider/me` (+`PUT /rider/me/status`) | ✅ real | `ProfileScreen` static mock | render + edit real profile |
| AC-3 | `POST /auth/refresh` | ✅ real | defined, unused | 401-retry via Dio interceptor |
| SAF-1 | `POST /sos` | ❌ STUB (ack only) | `SecurityScreen` "coming soon" | wire SOS button; banner "support notified", note backend doesn't persist yet |
| PAY-1 | `GET/POST/DELETE /rider/payment-methods` | ❌ STUB | `PaymentScreen` "coming soon" | SKIP — backend stub |
| PAY-2 | `POST /rides/:id/tip` | ❌ STUB | declared, unused | SKIP — backend stub |
| PROMO | promotions, places geocode/details, isochrone/heatmap, devices, feedback, verify-email/phone, all `/driver/*` | ❌ STUB / other-role | n/a | SKIP (see §6) |

---

## 3. Fix the WS contract first (bug, not just a feature)

Backend pushes **only**: `ride.offer` (driver), `ride.updated` (`pending/accepted/driver_arrived/in_progress/completed/cancelled/no_driver_available`), `driver.location`. Payload shapes (verified in `internal/websocket/messages.go`):

```jsonc
// ride.updated (accepted)
{ "type":"ride.updated", "data": {
  "ride_id":"...", "status":"accepted", "timestamp":"...",
  "eta_seconds":300, // real route driver→pickup ETA; 300 only when location/routing unavailable
  "driver": { "id":"...", "first_name":"...", "photo_url":"...", "rating":5.0,
              "vehicle": {"make":"...","model":"...","color":"...","plate_number":"..."},
              "location": {"lat":..,"lng":..,"heading":..} },
  "pickup": {"lat":..,"lng":..,"address":"..."}, "dropoff": {"lat":..,"lng":..,"address":"..."} }}
// ride.updated (completed)  → data.fare { base_fare, distance_fare, time_fare, surge_multiplier, total }
// ride.updated (cancelled)  → data.cancelled_by
// driver.location           → data { ride_id, driver_id, lat, lng, heading, speed }
```

**Current bugs in `ride_status_provider.dart`:**

| App listens for | Reality | Fix |
|---|---|---|
| `ride_matched` | backend never sends | delete branch |
| `driver_moved` | backend sends `driver.location` | rename branch → parse `DriverLocation` |
| `ride_arrived` | backend sends `ride.updated` status=`driver_arrived` | handle inside `ride.updated`, add `RideStatus.driverArrived` |
| `ride_completed` | backend sends `ride.updated` status=`completed` | remove duplicate branch |
| `status=="accepted"` uses raw map | data is `driver:{...}` | parse via existing (unused!) `DriverInfo`/`DriverVehicle`/`DriverLocation` models |
| no `cancelled` status | sent by backend on cancel | add `RideStatus.cancelled` → pop to home + toast |
| no `no_driver_available` status | **backend updates DB but pushes NO event** (`service/dispatch.go:59,78`) | poll `GET /rides/current` (LC-2); also flag backend gap |

Also `ActiveRideScreen` reads invented keys `driver_lat / driver_lng / driver_name / car_model` (`active_ride_screen.dart:68-72,132-133`) — must switch to the typed accepted `driver` object + `driver.location` / `GET /drivers/:id/location` stream.

Because the backend never pushes `no_driver_available`, `GET /rides/current` polling during driver-matching is **required** (every ~5–10 s, or on WS silence) to detect both `no_driver_available` and to restore a ride after reconnect.

---

## 4. Workstreams (implementation steps)

### WS-1 — Realign event handling
- **Files:** `features/home/data/ride_status_provider.dart` (model: `ride_status_provider.dart` and/or a new `features/home/model/ride_state.dart`).
- **Changes:**
  - Replace invented branches with backend contract (`ride.updated`, `driver.location`).
  - Add `RideStatus.driverArrived`, `RideStatus.cancelled`, `RideStatus.noDriverAvailable`; parse `driver`, `fare`, `cancelled_by`, `eta_seconds` into typed fields reusing `DriverInfo`/`DriverVehicle`/`DriverLocation` (`features/home/model/driver.dart`).
- **Tests:** `test/features/home/data/ride_status_provider_test.dart` — feed each backend-shaped event, assert state; assert `driver_moved`/`ride_matched`/`ride_arrived` are ignored.

### LC-1 — Real cancel ride
- **Files:** `features/home/data/home_provider.dart` (add `cancelRide()`), `features/home/presentation/active_ride_screen.dart`, `features/home/presentation/driver_matching_screen.dart` (add cancel/back that calls it during `pending`).
- **Changes:** `POST /rides/:id/cancel`; keep `_cancelRide` local → replace body with provider call; listen for `RideStatus.cancelled` from WS and route to `/home`.
- **Tests:** provider unit test (success + error); screen test asserting the endpoint is hit.

### LC-2 — Current-ride restore + no-driver detection
- **Files:** `features/home/data/ride_status_provider.dart` or new `features/home/data/current_ride_provider.dart`; `driver_matching_screen.dart`.
- **Changes:** `GET /rides/current` poll (every 5 s while `matching`); on `ride != null && status=="no_driver_available"` → cancel matching UI + toast; on app cold start during `pending/accepted/...` → restore into active-ride flow; also close gaps when WS drops.
- **Backend gap to log for later:** dispatch doesn't push `no_driver_available` — polling is the workaround.

### LC-3 — Ride detail on active-ride open + receipt on completion
- **Files:** `features/home/data/ride_provider.dart` (new: `fetchRide(id)`, `fetchReceipt(id)`), `active_ride_screen.dart`.
- **Changes:** on entering active ride, resolve ride id (from WS `ride_id` or `currentRide`) → `GET /rides/:id` for authoritative details; on `completed` open a fare breakdown dialog from `GET /rides/:id/receipt` (`receipt.{base_fare,distance_fare,time_fare,surge_multiplier,total}`) or the WS `fare` payload.
- **Tests:** provider parse tests; screen test renders receipt numbers.

### LC-4 — Live driver tracking (WS + polling fallback)
- **Files:** `features/home/presentation/active_ride_screen.dart`, `ride_status_provider.dart`.
- **Changes:** consume typed `driver.location` (update marker, re-center map); optional polling fallback `GET /drivers/:id/location` (every 5 s if no WS event for 10 s) using driver id from accepted payload.
- **Tests:** provider + screen; verify marker moves with injected events.

### LC-5 — Ride history
- **Files:** `features/home/data/history_provider.dart` (new), `features/home/presentation/history_screen.dart`.
- **Changes:** `GET /rides/history?page&per_page` → render list (pickup→dropoff, vehicle type, status, total fare) with paging/retry/empty/error states; replace static placeholder.
- **Tests:** provider (infinite-scroll pagination fields), screen widget test.

### LC-0 — Idempotency-key reuse
- **Files:** `features/home/data/home_provider.dart`.
- **Changes:** generate one key per booking *attempt* (keep in notifier state, reuse across retries; clear on success). Note backend replays empty body for repeated keys — retry UX must still re-fetch `GET /rides/current` to confirm.

### GEO-1 — Stream rider location
- **Files:** `features/home/data/home_provider.dart` or a small `location_ping_service`; `home_screen.dart` / `active_ride_screen.dart`.
- **Changes:** on a position fix, `PUT /geo/rider/location {lat,lng}` → 204; throttle to e.g. every 5 s while screen is active; stop on dispose/pause. (Backend uses it as the rider-side anchor for dispatch/ETA.)
- **Tests:** throttle logic unit test (inject clock), provider test with 204.

### GEO-3 — Use the dead `nearbyDriversProvider`
- **Files:** `home_screen.dart`, `home_provider.dart` (`nearbyDrivers`).
- **Changes:** watch provider, show "X drivers nearby" chip when requesting a trip; keep silent on error. (ETA per driver still stub-backed — don't claim it.)

### AC-1 — Real forgot password
- **Files:** `features/auth/presentation/forgot_password_screen.dart` (call `POST /auth/forgot-password {email}`; show success from response, error snack on failure; keep demo copy).
- **Tests:** screen test with mocked Dio.

### AC-2 — Real profile
- **Files:** `features/auth/model/auth_user.dart` (add `firstName`, `lastName`, `photoUrl`, `status`), `features/home/data/profile_provider.dart` (new: `GET /rider/me` → `{user, rider}`, `PUT /rider/me`), `profile_screen.dart`.
- **Changes:** render real name/email/phone from API; edit form (first/last name, phone) → `PUT /rider/me`; optional `PUT /rider/me/status` when toggling availability. Remove hardcoded "Rider"/"rider@example.com".

### AC-3 — 401 auto-refresh
- **Files:** `core/api/api_client.dart` (add `QueuedInterceptor` or dio `Interceptor` onError), uses `authProvider.refreshToken()`.
- **Changes:** on 401 → call `refreshToken()`; on success retry original request once (re-attach new bearer); on failure force logout. Guard against concurrent 401s (single-flight).

### SAF-1 — SOS button
- **Files:** `features/home/presentation/security_screen.dart`, `features/home/data/security_provider.dart` (new).
- **Changes:** "Emergency" button → `POST /sos {lat,lng}` using last known position; show confirmation; **note to user**: backend currently returns an ack without persisting/dispatching (track with PAY-1 as blocked-on-backend).

---

## 5. Non-goals / skip list (backend is still STUB — don't build UI around fake values)

`payment-methods` (all verbs), `rides/:id/tip`, promotions list/apply, `places/geocode` & `places/details`, `geo/isochrone`, `heatmap`, devices register/unregister (no push pipeline), `feedback`, `auth/social`, `auth/verify-email/phone`, and **all `/driver/*` endpoints and the driver's `ride.accept`/`ride.decline` WS messages** (driver app is out of scope).

---

## 6. Verification

- Per-task unit/widget tests in `rider_app/test/features/...` mirroring the existing suite (mocktail + `http_mock_adapter`).
- `flutter analyze` — zero new issues.
- `flutter test` — full pass (`rider_app`: `cd rider_app && flutter test`).
- Optional end-to-end: run `docker compose up -d` + `go run ./cmd/server`, launch app with `--dart-define=API_BASE_URL=...`, exercise request→match→accept→complete against the live backend (WS included); confirm `no_driver_available` shows after `POST /rides` with no online driver.

## 7. Suggested order & rough effort

| Order | Workstream | Effort |
|---|---|---|
| 1 | WS-1 contract realign (foundation) | M |
| 2 | LC-1 cancel + LC-2 current-ride poll (lifecycle core) | M |
| 3 | LC-3 receipt/rate + LC-4 driver tracking | M |
| 4 | LC-5 history, LC-0 idempotency, GEO-1 location ping | M |
| 5 | AC-1/AC-2/AC-3, GEO-3 chip | S each |
| 6 | SAF-1 (blocked-ish), skip list | S |
| — | Backend follow-ups to file as issues | cancel on `no_driver_available` WS push; real ETA; vehicle CRUD |

Blocks: WS-1 first (everything depends on correct event shapes); LC-2 unblocks `no_driver_available` UX; AC-3 unblocks long-lived sessions (token must refresh before WS disconnect for live tracking to keep working).