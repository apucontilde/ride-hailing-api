# Plan — Build the Driver App (`driver_app`) from zero

Scope: a new **Flutter driver app** (passenger side already exists as `rider_app/`). This plan builds the app end-to-end against the backend contract documented in `USER_STORIES.md` (v2) and verified against the code at `051ecaf`. It is written **from zero** — no skeleton exists yet.

> **Delivery status (audited 2026-09-25 against the working tree).** The
> milestone blueprint below is still the design of record, but the app was built
> incrementally through `driver_app_plans/STATUS.md` and its real state differs from
> this document's optimistic read. **Landed and tested:** P0–P1 (scaffold, M1
> auth, M2 onboarding) and plans 01–05 = M3, M4, M5, M6, M7 (online/location loop,
> offer sheet, accept/decline with the 30 s countdown and the HTTP fallback, the
> full trip journey: one stage per server status, the server route polyline with a
> >200 m refetch, driver cancel, the fare receipt, and a `GET /driver/rides/current`
> launch restore) plus M8/M9 (the paged ride history with a **client-side** earnings
> header, and rating the rider from the trip receipt or the history list). Current
> totals: **224 driver_app tests green, `flutter analyze` clean** in all three
> packages. Five bugs were fixed on the way — the old stage machine merged
> `accepted`/`driver_arrived`, so the first button press sent `in_progress` and the
> server answered 400; `ride.updated` was parsed as a flat `Ride` when the wire shape
> is a `ride_id`-keyed patch with nested `pickup`/`dropoff`/`fare`; the trip notifier
> never seeded from the ride already held, so the screen it was opened *for* rendered
> empty; the history page merge *prepended* the fetched page instead of appending it,
> inverting the newest-first order; and the tile's trailing column overflowed its
> `ListTile` slot by 8 px. Two contracts in `driver_app_plans/STATUS.md` `[history]` were also wrong
> against the handlers and are corrected there: the rate body field is `score`, not
> `rating`, and history pagination is 1-based `page`/`per_page`, not
> `limit`/`offset`.
> **Code landed, untested:** M10 (profile / gated vehicle / settings).
> **Not started:** the safety/support surface (SAF-1: `POST /sos` + `POST/feedback`
> are declared in `endpoints.dart` but never called), and M10's test suites.
> Turn-by-turn guidance is also still open — the map draws the road polyline, not a
> nav session. The fix-up order and the per-plan breakdown live in
> `driver_app_plans/STATUS.md`; the story-level tiers are in `USER_STORIES.md`
> (Part B + Appendix).

---

## 1. What we're building

A Flutter app that lets a driver:

1. Sign up (rider role) → get promoted to driver → **go online**
2. Keep a live WebSocket + location stream so the dispatcher offers them rides
3. Receive a `ride.offer`, inspect the trip, **accept or decline** (with a countdown)
4. Navigate to the pickup, signal **arrival**, **start the trip**, **complete** it, or **cancel** pre-pickup
5. Rate the rider, see **history/earnings** and their **profile**

Backed by the existing backend: JWT auth, driver role endpoints, pgRouting navigation, PostGIS dispatch (`500 m → 10 km` radii, up to **5** drivers, **30 s** per offer, live-WS-only), and the WebSocket hub.

### Story coverage (from `USER_STORIES.md`)

| Story | Status on backend | App delivers |
|---|---|---|
| US-D1 Create a driver account | ✅ `POST /auth/register` + `POST /driver/register` | Onboarding flow |
| US-D2 Log in | ✅ login/refresh/logout | Auth screens |
| US-D3 Set up profile & vehicle | 🚧 profile real, **vehicle CRUD is STUB** | Profile real; vehicle UI built but gated (see §4) |
| US-D4 Go online | ✅ status + location + `/ws` | Home availability toggle + location stream |
| US-D5 Receive a ride request | ✅ `ride.offer` (id only) + `GET /driver/rides/:id` | Incoming-ride dialog + auto detail fetch |
| US-D6 Accept the ride | ✅ WS `ride.accept`/`ride.decline` (+ HTTP accept fallback) | Accept/decline with expiry countdown |
| US-D7 Navigate to the pickup | ✅ `GET /navigation/route` | Navigation screen (map + polyline) |
| US-D8 Arrived at pickup | ✅ status `driver_arrived` (stub notify-arrival skipped) | Arrival button + WS feedback |
| US-D9 Start and complete the trip | ✅ status `in_progress`/`completed` | Trip controls + fare summary |
| US-D10 Rate the rider | ✅ `POST /driver/rides/:id/rate` | Rating screen after completion |
| US-11 Cancel a ride (driver side) | ✅ `POST /driver/rides/:id/cancel` (state machine enforced) | Cancel-trip action pre-pickup |
| US-D11 View history & earnings | 🚧 history real, **earnings/withdraw are STUB** | History list; earnings derived client-side (gated) |
| Real-time tracking | `driver.location` pushed to rider; driver receives `ride.updated` | Live updates via WS + polling fallback |

---

## 2. Backend contract (authoritative, verified)

### 2.1 Auth (shared with rider app)
- `POST /auth/register` `{email, phone, password}` → `201 {user:{..., role:"rider"}}`
- `POST /auth/login` `{email, password}` → `200 {access_token, refresh_token, user}` (role becomes `driver` after promotion)
- `POST /auth/refresh` `{refresh_token}` → rotates tokens; `POST /auth/logout` `{refresh_token}`
- Every protected call: `Authorization: Bearer <access_token>`

### 2.2 Driver endpoints (role `driver`)
| Endpoint | Request | Response | Notes |
|---|---|---|---|
| `POST /driver/register` | — | `201 {driver:{status:"offline", onboarding_status:"documents_submitted"}}` | promotes user to `driver` |
| `GET /driver/me` | — | `200 {driver:{user_id, first_name, last_name, photo_url, status, onboarding_status, rating_summary}}` | |
| `PUT /driver/me` | `{first_name, last_name, photo_url}` | `200 {driver}` | |
| `PUT /driver/me/status` | `{status:"online"\|"offline"}` | `200 {driver}` | enables dispatch |
| `GET /driver/rides/current` | — | `200 {ride: {...}\|null}` | role-based |
| `GET /driver/rides/history?page&per_page` | — | `200 {rides, total, page, per_page, total_pages}` | |
| `GET /driver/rides/:id` | — | `200 {ride}` | full detail incl. fare breakdown |
| `POST /driver/rides/:id/accept` | — | `200 {message}` / `409` | HTTP fallback (no active-offer check) |
| `PUT /driver/rides/:id/status` | `{status}` | `200 {ride}` | `driver_arrived` / `in_progress` / `completed` |
| `POST /driver/rides/:id/cancel` | — | `200 {ride}` | pre-pickup states only |
| `POST /driver/rides/:id/rate` | `{score:1..5, comment}` | `200 {message}` | persisted (no completed/party check — backend gap) |
| `PUT /geo/driver/location` | `{lat, lng, heading, speed}` | `204` | upserts online position; batch variant too |
| `GET /navigation/route?from_lat&from_lng&to_lat&to_lng` | — | `200 {polyline:[{lat,lng}], total_distance_m, total_duration_s}` | pgRouting |

**Stubs to work around (see §4):** `GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents`, `GET /driver/me/earnings`, `POST /driver/earnings/withdraw`, `GET /driver/rides/:id/rider` (hardcoded), `GET /driver/rides/queue`, `GET /driver/ratings`, `POST /driver/rides/:id/decline` (HTTP).

**Every driver-facing endpoint maps to an app screen** (exhaustive, from `router.go`):

| Endpoint | App surface |
|---|---|
| `POST /auth/register` / `login` / `refresh` / `logout` / `forgot-password` / `reset-password` | auth screens (**M1**) |
| `GET/PUT /driver/me` | profile screen (**M10**) |
| `PUT /driver/me/status` | online toggle (**M3**) |
| `POST /driver/register` | onboarding step (**M2**) |
| `GET/PUT /driver/me/vehicle`*, `GET/POST /driver/me/documents`* | vehicle/documents (gated, **M10**) |
| `GET /driver/me/earnings`*, `POST /driver/earnings/withdraw`* | earnings screen (derived) (**M9**) |
| `GET /driver/rides/current` | splash/active-ride restore (**M7**) |
| `GET /driver/rides/history` | earnings/history list (**M9**) |
| `GET /driver/rides/:id` | offer detail (**M4**) |
| `GET /driver/rides/:id/rider`* | rider info on trip screen (placeholder) |
| `POST /driver/rides/:id/accept` | accept (HTTP fallback) (**M5**) |
| `POST /driver/rides/:id/decline`* | (use WS decline only) |
| `PUT /driver/rides/:id/status` | trip state buttons (**M7**) |
| `POST /driver/rides/:id/cancel` | cancel-trip action (**M7**) |
| `POST /driver/rides/:id/rate` | rating screen (**M8**) |
| `POST /driver/rides/:id/notify-arrival`* | (skip; arrived status already notifies) |
| `GET /driver/rides/queue`*, `GET /driver/ratings`* | (no screen — stub, see §4) |
| `PUT /geo/driver/location` (+ `/batch`) | location stream (**M3**) |
| `GET /navigation/route` | pickup navigation screen (**M6**) |
| `GET /ws` | websocket service (**M3**) |
\* = backend stub (see §4).

### 2.3 Ride object (fields a driver consumes)
`id, rider_id, status, pickup_lat/lng/address, dropoff_lat/lng/address, vehicle_type, base_fare, distance_fare, time_fare, surge_multiplier, total_fare, requested_at, accepted_at, driver_arrived_at, started_at, completed_at, cancelled_at`
- State machine (backend-enforced, `service/ride.go:24-31`): `pending → accepted → driver_arrived → in_progress → completed`; `cancelled` from `pending|accepted|driver_arrived`.

### 2.4 WebSocket contract (`/ws`, Bearer header)
```jsonc
// driver RECEIVES
{ "type":"ride.offer", "data": {"ride_id":"..."} }                 // offer = id only → fetch detail
{ "type":"ride.updated", "data": { "ride_id":"...", "status":"accepted|driver_arrived|in_progress|completed|cancelled",
  "timestamp":"...", "eta_seconds":300,                                            // real driver→pickup route ETA; 300 only when location/routing unavailable — treat 300 as "unknown"
  "driver":{ "id":"...","first_name":"...","photo_url":"...","rating":5.0,          // contains the driver's OWN info
             "vehicle":{"make","model","color","plate_number"}, "location":{"lat","lng","heading"} },
  "pickup":{...}, "dropoff":{...}, "fare":{...}, "cancelled_by":"..." }}            // fare only on completed
// driver SENDS (persist-open socket; re-connect with backoff)
{ "type":"ride.accept",  "ride_id":"..." }
{ "type":"ride.decline", "ride_id":"..." }
{ "type":"ping" }  // → {"type":"pong"}
```
- Dispatch only offers to drivers with a **live `/ws` connection** (`hub.IsConnected`) — the socket must stay open and authenticated.
- Note: backend sends the driver its own `driver{...}` inside `accepted`, plus `driver_arrived`/`in_progress`/`completed`/`cancelled` to **both** parties.

---

## 3. App behavior model (offscreen state machine)

```
┌─offline──────────────────────────┐          (auth gate)
       │   online toggle = offline state? │
       ▼
   IDLE (online) ──dispatch──► OFFER_RECEIVED ──accept──► EN_ROUTE_TO_PICKUP
       ▲              ▲ cancel?▲      │decline/expire│             │ driver cancel
       │              │  (n/a)│       ▼              ▼             ▼
       └────── reset ◄┘       └─► IDLE            AT_PICKUP        IDLE ← driver
                                                       │driver cancel│  POST cancel
                                                       ▼              ▼
                                            ┌── driver completes ──► DONE ──rate──► IDLE
                                            └── rider cancels ────► CANCELLED ─────► IDLE
```
- **OFFER_RECEIVED** times out at 30 s (matches backend `time.After(30s)` in `service/dispatch.go:109`); decline → back to IDLE. Driver cannot "cancel" a ride it never accepted.
- **Driver cancel** (US-11 driver side): only legal from `accepted`/`driver_arrived` (state machine enforced) → `POST /driver/rides/:id/cancel` → toast + return to IDLE. Exposed on the trip screen as "Cancel trip".
- **CANCELLED** can also arrive from the rider at any pre-pickup state (`cancelled_by:"rider"`) → toast + return to IDLE.
- **completed** fare is 1.1× of estimate (backend hardcoded — do not present as GPS-accurate).
- A ride with no online drivers ends as `no_driver_available` (rider side only; driver unaffected).

---

## 4. Decisions forced by backend gaps

| Gap | Decision for the app | Backend follow-up (issue to file) |
|---|---|---|
| `ride.offer` carries only `ride_id` | Driver must `GET /driver/rides/:id` when the offer arrives; show a spinner until loaded. Prefetch is fine (200ms typical). | Richer offer payload (pickup/dropoff, fare, dist-to-pickup, TTL) |
| `GET /driver/rides/:id/rider` is a hardcoded stub | Show placeholder "Rider · ★5.0" gated behind a `useRealRiderInfo` flag; hide photo. Do NOT misrepresent. | Real rider name/photo/rating |
| Vehicle CRUD + documents are STUB | Build `VehicleScreen`/onboarding step against the intended contract but **gate behind a backend-ready feature flag**; hide until implemented. | `GET/PUT /driver/me/vehicle`, documents |
| `GET /driver/me/earnings` + withdraw are STUB | Earnings screen computes totals client-side from `GET /driver/rides/history`; **Withdraw entry hidden**. | Earnings + payout endpoints |
| `GET /driver/ratings` + `GET /driver/rides/queue` are STUB | Show the driver's rating from `driver.rating_summary` (already in `GET /driver/me`); no ratings-breakdown screen. No queue screen. | Ratings breakdown; real queue |
| `POST /driver/rides/:id/decline` (HTTP) is STUB | Use **WS `ride.decline`** for declining (works). Don't call the HTTP endpoint. | HTTP decline with reason |
| `POST /notify-arrival` is STUB | Skip it — `PUT /driver/rides/:id/status {driver_arrived}` already pushes `ride.updated` to the rider. | (none needed) |
| `eta_seconds` in accept payload is route-based but falls back to 300 when driver location/routing is unavailable; route duration = dist/11 | Compute distance-to-pickup client-side (haversine) for the offer card + countdown-looking ETA; trust the server ETA only when the location was present in the payload, else treat 300 as "unknown". | (none — ETA is already real from routing) |
| Ride ID may be needed in many screens | Thread the active ride (id + status) through the ride-state notifier; never store raw paging state in widgets. | — |

---

## 5. Project skeleton (mirrors `rider_app` conventions)

```
driver_app/
├── pubspec.yaml                # mirror rider_app deps (see below)
├── analysis_options.yaml       # flutter_lints
├── lib/
│   ├── main.dart               # ProviderScope + MaterialApp(routes from app_router)
│   ├── config.dart             # ApiConfig.baseUrl (String.fromEnvironment "API_BASE_URL")
│   ├── core/
│   │   ├── api/{api_client, api_exceptions, endpoints}.dart
│   │   ├── auth/{auth_provider, auth_storage}.dart
│   │   ├── network/websocket_service.dart
│   │   ├── router/app_router.dart
│   │   └── theme/app_theme.dart
│   ├── features/
│   │   ├── auth/              # register, login, splash, forgot & reset-password
│   │   ├── onboarding/        # US-D1: driver-registration screen(s)
│   │   ├── home/              # US-D4: online toggle, nearby status, offer banner
│   │   ├── ride/              # US-D5..D9: offer dialog, trip screens, providers
│   │   ├── navigation/        # US-D7: pickup nav screen (flutter_map + polyline)
│   │   ├── earnings/          # US-D11: history + derived totals
│   │   ├── profile/           # US-D3: profile + vehicle (gated)
│   │   └── settings/          # sign-out, app info
│   └── shared/                # widgets (status chip, pickup/dropoff card), utils, models
└── test/
```

**pubspec deps** (match rider_app for consistency): `flutter_riverpod` `^2.6.1`, `dio` `^5.7.0`, `go_router` `^14.8.0`, `flutter_secure_storage 10.0.0`, `flutter_map` `^7.0.2`, `latlong2` `^0.9.1`, `geolocator` `^13.0.2`, `web_socket_channel` `^3.0.2`, `image_picker` `^1.1.2`, `url_launcher`, `share_plus`; dev: `mocktail`, `http_mock_adapter`, `riverpod_generator`, `build_runner`, `flutter_lints ^6.0.0`. SDK `^3.12.2`, Flutter 3.44.

---

## 6. Feature-by-feature build plan (mapped to US-D#)

### M1 — Auth (US-D2, foundation)
- **Files:** `core/api/*`, `core/auth/*`, `features/auth/{login,register,splash,forgot_password,reset_password}_screen.dart`, `core/router/app_router.dart`, `shared/widgets/auth_text_field.dart`.
- **Work:** same as rider_app auth: register → auto-login → **then onboarding gate**; store tokens in `flutter_secure_storage`; set `ApiClient` bearer; **401 auto-refresh via Dio interceptor** (single-flight, retry once, else force logout) — taken from the AC-3 item in the rider plan, built-in from day one here. Forgot password posts `POST /auth/forgot-password {email}` → shows a **reset-password screen** (`POST /auth/reset-password {token, new_password}`) as the recovery link destination.
- **Tests:** `test/features/auth/*_test.dart`, `test/core/auth/auth_provider_test.dart` (mirror rider_app).

### M2 — Onboarding to driver (US-D1)
- **Screens:** `/onboarding` multi-step: ① welcome/terms ② identity (first/last name, photo picker) ③ driver-register.
- **Data:** `POST /driver/register` → store `onboarding_status`; update local `AuthUser.role` → `driver`; router redirect now permits driver routes.
- **Gating:** driver registration only when logged-in user role is `rider`.
- **Tests:** provider test (register → role change), widget test for the step state.

### M3 — Online/offline + live location (US-D4) — **the core loop**
- **Files:** `core/network/websocket_service.dart` (same reconnect/backoff logic as rider_app, but with **send** methods + received-message bus), `features/home/{home_screen, home_provider, online_status_provider}.dart`.
- **Data:**
  - Toggle online: `PUT /driver/me/status {online|offline}`.
  - Location stream: `geolocator` position stream → throttle → `PUT /geo/driver/location {lat,lng,heading,speed}` every ~5 s while online (batch variant optional off).
  - WS: connect with token **before** going online; keep alive; `ping` every 30 s; auto-reconnect 5 s backoff.
  - On `offline` or app background: stop location stream + disconnect WS in the right order so dispatch never sees an online-but-absent driver.
- **Home screen:** availability switch, vehicle/person summary, current status, "no driver wants it live" state.
- **Tests:** throttle unit test; provider tests for online/offline transitions and WS lifecycle (mock sink).

### M4 — Incoming ride offer + detail (US-D5)
- **Files:** `features/ride/{offer_provider, offer_dialog, ride_models.dart}`.
- **Data:** WS `ride.offer` → set `OFFER_RECEIVED` with 30 s countdown → parallel `GET /driver/rides/:id` → render pickup/dropoff address, vehicle_type, fare breakdown (`base_fare, distance_fare, time_fare, surge_multiplier, total_fare`), haversine distance from driver's own last position.
- **Redelivery rule:** ignore offers for a ride already handled; a new offer while one is showing queues or replaces per UX decision (pick: replace + toast).
- **Tests:** offer_provider with mocked WS events + mock adapter for the detail fetch; countdown widget test.

### M5 — Accept / decline with HTTP fallback (US-D6)
- **Files:** extend `offer_provider.dart`, ride screen actions.
- **Data:** primary `send('ride.accept', {ride_id})`; fallback button for offline-agent mode: `POST /driver/rides/:id/accept` (map `409` → "taken" toast → back to IDLE). Decline via `send('ride.decline', {ride_id})` only. On accept → `ride.updated(status:accepted)` flips state to `EN_ROUTE_TO_PICKUP`.
- **Tests:** accept/decline path via WS; HTTP 409 handling; no active WS + HTTP accept still works.

### M6 — Navigate to pickup (US-D7)
- **Screen:** `/trip` map (flutter_map) with pickup marker + polyline from `GET /navigation/route?from_lat&from_lng&to_lat&to_lng` (driver location → pickup), bottom sheet with address + status chip + **primary action** button (state-dependent: Navigate → Arrived → Start trip → Complete).
- **Data:** route fetch is heavy for nav — cache per (from,to) pair; refetch only on >200 m movement if needed.
- **Tests:** route parsing test; screen state button matrix test.

### M7 — Arrived / Start / Complete (US-D8, US-D9)
- **Files:** `features/ride/trip_provider.dart`, trip screen.
- **Data:** state machine drives the single primary button:
  - `accepted` → `PUT /driver/rides/:id/status {driver_arrived}` → await WS `ride.updated(driver_arrived)`
  - `driver_arrived` → `{in_progress}` → await WS `in_progress`
  - `in_progress` → `{completed}` → WS `completed` includes `fare` → show summary
  - `completed` → navigate to rating.
- **Safety:** disable button while a transition is in flight; surface backend `400` transition errors; handle rider `cancelled` mid-trip (toast + back to IDLE).
- **Cancel trip (US-11 driver side):** visible on the trip screen while in `accepted`/`driver_arrived` → `POST /driver/rides/:id/cancel` → confirm → toast + back to IDLE. Not offered once `in_progress` (state machine disallows it, and the rider is aboard).
- **Tests:** trip_provider transition test with WS-mock; double-tap guard test; driver-cancel path (WS `cancelled` echo + button state hide once `in_progress`).

### M8 — Rate the rider (US-D10) ✅ landed (`driver_app_plans/STATUS.md` `[history]`)
- **Screen:** `/rate` with 1–5 stars + optional comment.
- **Data:** `POST /driver/rides/:id/rate {score, comment}` → confirm → go home (idle). Backend has no completed/party check — fine for the app; don't harden client-side beyond disabling double-submit.
- **Tests:** provider + widget test.
- *As landed:* a modal `RateSheet` rather than a `/rate` route, reachable from the post-trip receipt and from each completed trip in the history list. The body field is `score` (a `rating` key binds to zero and 400s). Double-submit is blocked by disabling the control in flight, and a failure keeps the sheet open with an inline error. "Already rated" is tracked in-session because `GET /driver/ratings` is a stub.

### M9 — Earnings & history (US-D11) ✅ landed (`driver_app_plans/STATUS.md` `[history]`)
- **Files:** `features/earnings/{earnings_screen, earnings_provider, ride_tile_widget}.dart`.
- **Data:** `GET /driver/rides/history?page=1&per_page=20` (infinite scroll using `total_pages`); totals (rides, sum `total_fare`, by-day grouping) computed client-side; **withdraw section hidden** (backend stub).
- **Tests:** pagination provider test (mock adapter two pages); widget test renders totals.
- *As landed:* under `features/rides/` instead of `features/earnings/`, reusing the existing repository and the `/rides-history` route the profile screen already linked. Bucketing is by **month**, not by day, and exhaustion follows the page length rather than `total_pages` — a row that loses its id is dropped from the list but still counts towards the server's `total`. Because history is paginated, the earnings header states that it covers only the trips loaded so far.

### M10 — Profile & settings (US-D3)
- **Files:** `features/profile/{profile_screen, profile_provider}.dart`, `features/settings/settings_screen.dart`.
- **Data:** `GET /driver/me` + `PUT /driver/me {first_name, last_name, photo_url}` (photo via `image_picker` → URL field; backend stores URL, no upload endpoint — note). Driver's own rating shown from `driver.rating_summary` in `GET /driver/me`.
- **Vehicle & documents:** `VehicleScreen` built against `GET/PUT /driver/me/vehicle {make, model, color, plate_number, year, vehicle_type}` and `GET/POST /driver/me/documents` **rendered only when the backend feature flag is on** (backend stub today).
- **Settings:** sign-out (WS disconnect → `POST /auth/logout` → clear storage), app/API version, help link.
- **Optional (low priority):** SOS action in settings/trip overflow → `POST /sos {ride_id}` (backend only broadcasts to WS peers — no dispatch/alert, so treat as ack-only, same caveat as rider app SAF-1); feedback entry → `POST /feedback`.

---

## 7. Shared pieces

- **`shared/models/`:** `ride.dart` (parses the backend Ride object verbatim), `driver.dart`, `location_event.dart`, `fare.dart` — unit tests for all `fromJson`.
- **`shared/providers/active_ride_provider.dart`:** single source of truth for the driver's current ride (`GET /driver/rides/current` on cold start + WS mutations + `GET /driver/rides/:id` refreshes), so app restart mid-trip lands back in the right state.
- **Map util:** same OSM tile + `NetworkTileProvider` setup as rider_app (Windows dev flexibility; mobile UA override).
- **Splash:** auth check → route to `/login`, `/onboarding`, or `/home`.

---

## 8. Phased milestones

| Phase | Milestone | Output gate |
|---|---|---|
| P0 | `driver_app/` scaffold + core (api/auth/ws/router/theme) | `flutter create`, builds, `flutter analyze` clean |
| P1 | M1 auth + M2 onboarding | login→driver home E2E with live backend |
| P2 | M3 online/location loop | driver visible in `GET /geo/nearby-drivers` when online |
| P3 | M4–M5 offers & accept/decline | end-to-end: rider books → driver gets live offer → accept |
| P4 | M6–M8 trip journey + rating | full lifecycle against live backend (arrived/in_progress/completed) |
| P5 | M9 earnings + M10 profile/settings | tests green, `flutter test -r expanded` |
| P6 | Polish: offline banners, retry states, app icon/name, README | QA pass |

**Estimated effort:** P0–P1 ~1 day · P2–P3 ~1.5 days · P4 ~1.5 days · P5 ~1 day · P6 flexible. (Single-dev, mirroring rider_app conventions.)

---

## 9. Verification

- **Per feature:** unit/widget tests in `driver_app/test/...` using `mocktail` + `http_mock_adapter` (mirror rider_app idioms); never skip the WS provider tests.
- **Static:** `cd driver_app && flutter analyze` → 0 issues; `flutter test` full pass.
- **E2E (live backend):**
  1. `docker compose up -d` + `go run ./cmd/server`
  2. Register rider **and** driver accounts (driver via `/onboarding`)
  3. Driver online → build with `--dart-define=API_BASE_URL=...`
  4. Rider books trip → observe `ride.offer`, engage 30 s countdown, accept
  5. Walk arrived → in_progress → completed; confirm rider saw `driver.location` stream and gets the fare
  6. Negative paths: decline → offer expires → **driver cancel** (`accepted` state) → rider cancel → HTTP `409` race; kill WS and confirm 5 s reconnect.

---

## 10. Backend follow-ups to file as issues (block/inform this app)

1. Richer `ride.offer` payload (pickup/dropoff, fare, distance, expiry TTL) — `service/dispatch.go:101-104`.
2. Real `GET/PUT /driver/me/vehicle` + `GET/POST /driver/me/documents` (unblock US-D3).
3. Real `GET /driver/rides/:id/rider` (currently hardcoded, `handler/platform.go:340`).
4. Real `GET /driver/me/earnings` + `POST /driver/earnings/withdraw` (unblock earnings section).
5. HTTP `POST /driver/rides/:id/decline` (WS decline already works).
6. Keep accept ETA accurate end-to-end: it already routes driver→pickup, but falls back to `300` when driver location/routing is unavailable (`service/dispatch.go:160-184`); long-term, real duration from GPS.
7. Completion fare from actual GPS, not `*1.1` (`service/ride.go:166-169`).