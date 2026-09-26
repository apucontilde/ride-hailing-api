# driver_app — Incremental Build Plans (index)

Goal: take the **bootstrapped** `driver_app/` (P0 scaffold + core + auth/onboarding,
created against `DRIVER_APP_PLAN.md` and `USER_STORIES.md`) and make it *really drive*
every driver-facing capability that the backend API and `rider_app` currently offer.
Each plan below is **self-contained and small** — a fresh model context window can
execute it by reading *this file only* plus the `Facts` sections it embeds, then
applying the changes to `driver_app/`. The authoritative contract source is
`USER_STORIES.md` (Part B + Appendix) and `DRIVER_APP_PLAN.md`; where those disagree
with the code, the code wins and the plan says so.

## How the bootstrap is wired today (what plans build on)

Bootstrap deliverables (verify with `git log -- driver_app`):

- **Scaffold + core:** `flutter create` project, `pubspec.yaml` mirroring
  `rider_app` deps, `lib/{main,app,config}.dart`,
  `lib/core/{api,auth,network,router,theme,utils}/...`.
- **API client:** `core/api/api_client.dart` (Dio base URL from
  `API_BASE_URL` env, **401 single-flight auto-refresh built in** → `core/api/api_exceptions.dart`),
  endpoint registry `core/api/endpoints.dart` covering the full driver surface.
- **Auth:** `core/auth/{auth_storage,auth_provider}.dart` — checks
  `GET /driver/me` on cold start (403 → session kept as rider, routed to
  onboarding), logs in/out, and `registerAsDriver()` rotates the JWT past
  `POST /driver/register` so `role` becomes `driver`.
- **WebSocket:** `core/network/websocket_service.dart` —
  broadcast `events` stream + `acceptOffer`/`declineOffer`/`ping` send helpers.
  **Uses the backend's real nested payload shape** (`{"type":"ride.accept","data":{"ride_id":...}}`).
- **Router + screens:** `core/router/app_router.dart` gates
  unauthenticated → `/login`, rider-role → `/onboarding`,
  driver → `/home`; auth screens (login / register / forgot / reset) + onboarding
  + minimal home / profile / settings.
- **Tests:** the bootstrap landed `test/core/...` (api_client, auth_provider,
  auth_storage, validators, router) + a widget smoke = **50 passing**. Plans 01–05
  added the WS, ride-state, availability, location, rides-repository, offer-sheet,
  trip-notifier, trip-screen, home-screen, history-provider, rate-sheet and
  history-screen suites. Current total: **171 passing**
  in `driver_app` (+24 `shared`, +102 `rider_app`), `flutter analyze` clean in all
  three packages.

Plans 01–07 below pick up from here. Endpoint cells in `USER_STORIES.md` flip to
🟢/🟠 only after a plan lands its tests.

## Implementation status (audited 2026-09-25)

Bootstrap ✅ · plans 01–05 ✅ landed · **06 🟠 code landed / tests missing** ·
**07 🟠 skip list only**. Current totals:
**171 driver_app tests, all green** (+24 `shared`, +102 `rider_app`), `flutter
analyze` clean in all three packages (`make flutter-analyze`,
`make flutter-test`). The remaining work is *two small slices* (06's three
missing test suites, 07's safety screen) — not a rewrite.

| Plan | Status | Landed | Still open |
|---|---|---|---|
| `01_ws_contract.md` | ✅ | `ws_event.dart`, `DriverWebSocketService` typed facade, `RideStateNotifier` (offer + 30 s expiry + current ride + `lastLocation` + the `ride.updated` patch merge), WS + notifier tests | `lastLocation` still has no consumer, and never will — the server only pushes `driver.location` to the **rider**, so the driver app has no rider feed to draw (see plan 04's corrected boundary logic) |
| `02_online_status_loop.md` | ✅ | `AvailabilityNotifier` (double-tap guarded, reverts on failure), `LocationService` (≥5 s throttle, online-only, 60-point bounded buffer + batch flush, `lastPositionProvider` + `onPosition` for the trip map), reworked home screen, both suites green | `appPermissionProvider` is never written by `requestPermission()`, so the "denied" banner can't fire; `app.dart`'s two authenticated branches are redundant |
| `03_offer_and_accept.md` | ✅ | `RidesRepository.fetchRide` + `acceptRideHttp` (409 → `OfferExpiredException`), `OfferSheet` (5 s detail load, 30→0 countdown, WS-first accept w/ HTTP fallback, WS-only decline, single-offer policy), home wiring, both suites green | no base/surge fare breakdown in the sheet (presentation only) |
| `04_trip_journey_navigation.md` | ✅ | `TripNotifier` (one stage per server status, `advance`, `cancelTrip`, destination-anchored route cache with a >200 m haversine refetch), `TripScreen` (flutter_map + driver marker, road polyline over a dashed fallback, per-stage button, complete/cancel confirms, fare receipt, cancelled notice, `clearRide()` on terminal), home → `/trip` push + "Active trip" banner, `GET /driver/rides/current` launch restore, 46 new tests across 4 suites | no live rider pin (no rider feed exists — see plan 01 row); turn-by-turn guidance |
| `05_earnings_history_rating.md` | ✅ | `RidesRepository.history` + `rateRide` (**two contract corrections vs. the doc below**: the body field is `score` not `rating`, and pagination is `page`/`per_page` not `limit`/`offset`), `HistoryNotifier` (paged, id-deduped, concurrency-collapsed, pull-to-refresh) + derived `earningsProvider` bucketed by completion month, real `RidesHistoryScreen` (earnings header, infinite scroll, per-trip rating), `RateSheet` + `ratedRideIdsProvider`, post-trip rating prompt on the trip receipt, home drawer entry, 50 new tests across 4 suites | no withdraw UI (the endpoint is a stub); the "already rated" set is session-local — `GET /driver/ratings` is a `StubPayment` and history carries no rated-by-driver flag, so there is nothing to read back |
| `06_profile_settings_gated.md` | 🟠 | `ProfileNotifier.updateProfile` (partial fields, cache replace, error preserve), full profile screen (avatar, chips, ★ rating, validated edit form), gated vehicle screen, settings (sign-out + version + server) | **no tests at all** — the three suites this plan requires are missing. Also: onboarding collects first/last name and never `PUT`s it (US-D1 🟡) |
| `07_safety_support_skip.md` | 🟠 | the skip list itself (re-verified still accurate) | `safety_screen.dart` / `safety_repository.dart` don't exist; `POST /sos` + `POST /feedback` are declared but never called (US-12 still ack-only-missing). Cheapest win on the board |

### Recommended next slice

1. **Then 07's safety screen** — two small files, closes US-12, and the backend
   (`POST /sos`, `POST /feedback`) is real rather than a stub, so it needs no
   gating decision.
2. **Then 06's three missing test suites** — protects already-shipped code
   (profile, vehicle, settings) with no behaviour change.

Endpoint coverage today: **21 of 31** declared driver endpoints are actually invoked
(20 HTTP + `/ws`; full list in the `USER_STORIES.md` wiring summary). Plan 05 moved
`GET /driver/rides/history` and `POST /driver/rides/:id/rate` off the dead list. ⚠️ The
previous audit said "18 of 31" and was **off by one** — it forgot
`GET /driver/rides/:id` (`driverRideById`, a function-style endpoint), so the count
before plan 05 was 19, not 18.
`GET /driver/me/vehicle` has a call site but sits behind a disabled feature flag.
The uninvoked ones are exactly the plan-07 backlog plus the stub entries in
plan 07's skip list.

## Plans

| File | Work | Depends on | Status |
|---|---|---|---|
| `01_ws_contract.md` | Driver WS receive/send contract + ride-state machine notifier (**do first**) | bootstrap | ✅ |
| `02_online_status_loop.md` | US-D4 online/offline toggle + live location stream (core loop) | 01 | ✅ |
| `03_offer_and_accept.md` | US-D5/D6 offer dialog + 30 s countdown + accept (WS + HTTP fallback) / decline (WS) | 01, 02 | ✅ |
| `04_trip_journey_navigation.md` | US-D7/D8/D9/US-11 nav + single-button state machine + driver cancel | 03 | ✅ |
| `05_earnings_history_rating.md` | US-D10/D11 history + client-side earnings + rate rider | 04 | ✅ |
| `06_profile_settings_gated.md` | US-D3 profile/vehicle (feature-gated) + settings + identity via photo | none | 🟠 untested |
| `07_safety_support_skip.md` | SAF-1 SOS + feedback (ack-only) + explicit skip list + backend follow-ups | 01 | 🟠 skip list only |

Expected order: 01 → 02 → 03 → 04 → [05, 06, 07]. Nothing requires another plan to
pass first except as noted. **Resume point:** 05 is done — pick up 07's safety
screen (two files, closes US-12), then 06's three missing test suites.

## Facts everything relies on (re-audited against the working tree)

- **Base URL:** `{API_BASE_URL}/api/v1` via `lib/core/api/endpoints.dart`;
  protected calls send `Authorization: Bearer <access_token>`; the added
  `via ApiClient` single-flight refresh is on and must not be reimplemented.
- **WS wire format (drivers SEND and RECEIVE):** every backend WS message is
  `{"type":"...","data":{...}}`. The driver **sends** `ride.accept`,
  `ride.decline`, `ping`; it **receives** `ride.offer` (data = `{ride_id}` only),
  `ride.updated` (statuses `pending/accepted/driver_arrived/in_progress/completed/cancelled`,
  plus `driver`, `pickup`, `dropoff`, `fare` on completed, `cancelled_by`), and
  `driver.location`. ⚠️ `DRIVER_APP_PLAN.md` §2.4 shows the flat form
  `{"type":"ride.accept","ride_id":...}` — that **does not work**: the hub
  unmarshals `ride_id` from `incoming.Data` (`internal/websocket/hub.go:95-110`),
  so the nested `data` wrapper is mandatory. Plans 01/03 enforce nested sends in
  `WebSocketService`.
- **Dispatch contract:** offers only go to drivers whose `/ws` is live
  (`internal/service/dispatch.go:97`); radii `{500..10000}m`, ≤5 drivers, **30 s**
  expiry (`dispatch.go:45-48,122`). An offer contains only `ride_id` → the app must
  fetch `GET /driver/rides/:id`.
- **Ride object** (for `shared/models/ride.dart`, plan 03): `id, rider_id, status,
  pickup_lat/lng/address, dropoff_lat/lng/address, vehicle_type, base_fare,
  distance_fare, time_fare, surge_multiplier, total_fare, requested_at,
  accepted_at, driver_arrived_at, started_at, completed_at, cancelled_at,
  cancelled_by`. State
  machine enforced server-side: `pending → accepted → driver_arrived →
  in_progress → completed`; `cancelled` from `pending|accepted|driver_arrived`.
- **HTTP endpoints already consumed by the bootstrap:** `POST /auth/register`,
  `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout`,
  `POST /auth/forgot-password`, `POST /auth/reset-password`,
  `GET /driver/me`, `POST /driver/register`, `/ws`. Do not rewire them.
- **Backend stubs the app must not build UI around:** `GET/PUT /driver/me/vehicle`,
  `GET/POST /driver/me/documents`, `GET /driver/me/earnings`,
  `POST /driver/earnings/withdraw`, `GET /driver/ratings`,
  `GET /driver/rides/queue`, `GET /driver/rides/:id/rider`,
  `POST /driver/rides/:id/decline` (HTTP), `POST /driver/rides/:id/notify-arrival`,
  `POST /sos`, `POST /feedback`. `rider_app`'s rule applies: never build a real
  surface on a stub — gate or skip (see 07). ⚠️ Two of these got *more* real in
  plan 05, which corrected this list: `/driver/rides/history` and
  `/driver/rides/:id/rate` are **not** stubs, and the rate body field is `score`
  (not `rating`). `GET /driver/ratings` staying a stub is why "already rated" can
  only be tracked in-session.

## Golden rules

1. Tests: `mocktail` + `http_mock_adapter`, mirroring the suites in
   `driver_app/test/core/...` (do not read the whole repo first — the plan embeds
   the payloads).
2. Never build UI around a backend STUB (skip list in `07_safety_support_skip.md`).
3. Don't remove public providers used by other screens; extend them. Keep
   `core/auth/auth_provider.dart` the single owner of session/token state.
4. The ride-state machine owns the primary button; widgets never hold paging state.
5. Dart can't be compiled in this harness — be conservative, keep
   `flutter analyze` and `flutter test` green after every plan.

## Verification (every plan)

```bash
# From the repo root; the Melos workspace runs Flutter via Windows interop:
make flutter-analyze
make flutter-test
# live backend:
cd /mnt/c/Users/Ricardo/repos/ride-hailing-api && docker compose up -d && make run
```

Optional live E2E: register rider + driver accounts (driver via `/onboarding`),
go online, book from the rider app, accept, drive the state machine, rate.