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
- **Tests:** `test/core/...` (api_client, auth_provider, auth_storage,
  validators, router) + widget smoke = **50 passing**, `flutter analyze` clean.

Plans 01–07 below pick up from here. Endpoint cells in `USER_STORIES.md` flip to
🟢/🟠 only after a plan lands its tests.

## Plans

| File | Work | Depends on |
|---|---|---|
| `01_ws_contract.md` | Driver WS receive/send contract + ride-state machine notifier (**do first**) | bootstrap |
| `02_online_status_loop.md` | US-D4 online/offline toggle + live location stream (core loop) | 01 |
| `03_offer_and_accept.md` | US-D5/D6 offer dialog + 30 s countdown + accept (WS + HTTP fallback) / decline (WS) | 01, 02 |
| `04_trip_journey_navigation.md` | US-D7/D8/D9/US-11 nav + single-button state machine + driver cancel | 03 |
| `05_earnings_history_rating.md` | US-D10/D11 history + client-side earnings + rate rider | 04 |
| `06_profile_settings_gated.md` | US-D3 profile/vehicle (feature-gated) + settings + identity via photo | none |
| `07_safety_support_skip.md` | SAF-1 SOS + feedback (ack-only) + explicit skip list + backend follow-ups | 01 |

Expected order: 01 → 02 → 03 → 04 → [05, 06, 07]. Nothing requires another plan to
pass first except as noted.

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
  accepted_at, driver_arrived_at, started_at, completed_at, cancelled_at`. State
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
  surface on a stub — gate or skip (see 07).

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