# Ride-Hailing App User Stories — v2

Two companion apps — a **Rider app** (passenger) and a **Driver app** — both talk to the same backend (`ride-hailing-api`). This document walks the full journey of one rider booking a trip and one driver receiving and accepting that trip, expressed as concise user stories. Every API call references the OpenAPI spec at `docs/swagger.json` (browseable at `/docs`), which is the source of truth for request/response schemas.

**Version 2** — this revision was audited against the codebase at commit `051ecaf` (HEAD, 2026-09-06). Every story below carries a status tag and a *code state* note pointing at the exact implementation so the tag is verifiable and stays honest when the code moves. This revision also adds a **status on all three axes** — backend API, Rider app, and Driver app — per story and per endpoint (see the legend and the Appendix matrix). App-tier facts were audited against `rider_app/`; the driver app does not exist yet and is planned (`DRIVER_APP_PLAN.md`).

## Status legend

Two tiers are tracked side by side. A feature can be real at one tier and missing or fake at another, so every story and every endpoint states its status on each axis.

### API tier (backend)

| Tag | Meaning |
|---|---|
| **[IMPLEMENTED]** | Real logic, real DB/service-backed behavior. Works end-to-end as described. |
| **[PARTIAL]** | Works but with gaps: some sub-paths are stubs, values are hardcoded, or persistence is incomplete. |
| **[STUB]** | Returns a placeholder/acknowledgment only. Nothing real happens behind it. |
| **[MISSING]** | No endpoint/route exists at all. |

### App tier (Rider app / Driver app)

| Mark | Meaning |
|---|---|
| 🟢 wired | The app calls this endpoint / implements this story against the real backend contract and renders real data. |
| 🟠 wired–stub | The app calls the endpoint correctly, but the backend still returns stub data (none today — first cases appear when a build plan wires a STUB endpoint). |
| 🟡 partial | Partly in place but with gaps: a mix of real and fake within the same story/surface. |
| ❌ stubbed | The app ships a fake/placeholder instead of calling the API. |
| ⚪ not implemented | Not created yet (driver app today), or the endpoint is declared but never invoked in the app code. |
| — n/a | The endpoint/story does not apply to that app (e.g. driver-only endpoints for the rider app). |

### Decision rule (how each status was chosen)

- A story tag (`[IMPLEMENTED]` / `[PARTIAL]` / `[STUB]`) **always refers to the backend API tier**; the app tiers are stated separately on the same line. A `[PARTIAL]`/`[STUB]` tag does **not** imply the app is broken — check the app tier separately (e.g. US-11 is `[IMPLEMENTED]` on the API while the rider-app cancel is ❌ stubbed).
- App **wired to a STUB backend** → app is **🟠 wired–stub**: the call works, the data does not. No such cells today — the first ones appear when a build plan (`rider_app_plans/`) wires a currently-stubbed endpoint.
- App ships a **fake screen or mock** instead of the real call → app is **❌ stubbed** (e.g. US-14 history, US-11 cancel).
- Backend real but the app **never invokes the endpoint** (declared or not) → app is **⚪ not implemented**.
- Backend **[STUB]** and app **⚪** → nothing to decide, both tiers agree.
- **Driver app:** no `driver_app` exists today, so every driver-app cell is **⚪** and Part B stories read `Driver app: ⚪ not created`; the build plan lives in `DRIVER_APP_PLAN.md`.
- **Matrix freshness:** an endpoint cell flips to 🟢/🟠 only after the related build plan lands and `flutter test` passes — tracked per-plan in `rider_app_plans/` (none applied yet, plans 01–07 pending).

## Status summary (quick reference)

### Part A — Rider app

| Story | API | Rider app | Driver app |
|---|---|---|---|
| US-1 Sign up | [IMPLEMENTED] register + forgot/reset real; verify partial | 🟡 register real; forgot-password screen fake; verify ⚪ | — n/a |
| US-2 Log in | [IMPLEMENTED] login / refresh (rotation) / logout | 🟡 login/logout wired; auto-refresh never triggered | — n/a |
| US-3 Set pickup & destination | [PARTIAL] places autocomplete real; geocode/details stub | 🟡 autocomplete wired; no reverse-geocode | — n/a |
| US-4 See the price & ETA | [IMPLEMENTED] real fare engine + route-based ETA | 🟡 live price wired; eta endpoint ⚪ | — n/a |
| US-5 Request the trip | [IMPLEMENTED] create + dispatch; idempotency partial | 🟢 create ride + idempotency-key reuse wired | — n/a |
| US-6 Wait for a driver | [IMPLEMENTED] full dispatch loop (radii, 5 drivers, 30s) | 🟡 WS receive wired; invented event names break matched/cancelled | — n/a |
| US-7 Track the matched driver | [IMPLEMENTED] driver.location streaming + polling real; ETA real | ⚪ tracking broken (invented keys); driverLocation unused | — n/a |
| US-8 Ride in progress | [IMPLEMENTED] pgRouting nav real; destination-update stub | ⚪ no route fetch in app | — n/a |
| US-9 Trip complete & fare | [IMPLEMENTED] receipt real; completion fare is 1.1× | ⚪ receipt endpoint unused | — n/a |
| US-10 Rate the driver | [IMPLEMENTED] rating persisted; read-back stub | ⚪ rate endpoint unused | — n/a |
| US-11 Cancel a ride | [IMPLEMENTED] rider + driver cancel | ❌ 1s in-app mock; cancelRide unused | — n/a |
| US-12 Send an SOS | [STUB] ack only | ⚪ sos endpoint unused | — n/a |
| US-13 Profile & devices | [PARTIAL] rider profile real; devices stub | 🟡 GET /rider/me used for auth; profile screen hardcoded; PUT/devices ⚪ | — n/a |
| US-14 Ride history | [IMPLEMENTED] paginated DB query | ❌ fake "No rides yet" screen; ridesHistory unused | — n/a |
| US-15 View the fare receipt | [IMPLEMENTED] receipt real; completion fare 1.1× | ⚪ receipt unused (plan 03) | — n/a |
| US-16 No driver available | [PARTIAL] no WS push; reliable via `GET /rides/current` poll | ⚪ not implemented (plan 02) | — n/a |
| US-17 Re-book from history | [IMPLEMENTED] history paginated | ⚪ not implemented (plan 04) | — n/a |

### Part B — Driver app

| Story | API | Rider app | Driver app |
|---|---|---|---|
| US-D1 Create a driver account | [IMPLEMENTED] role promotion + driver row | — n/a | ⚪ not created — planned: onboarding (P1) |
| US-D2 Log in | [IMPLEMENTED] same auth as rider | — n/a | ⚪ not created — planned: auth screens (P1) |
| US-D3 Set up profile & vehicle | [PARTIAL] profile real; vehicle CRUD **stub** (read path real) | — n/a | ⚪ not created — planned: profile; vehicle gated (M10) |
| US-D4 Go online | [IMPLEMENTED] status + location streaming + /ws | — n/a | ⚪ not created — planned: online toggle + location stream (M3) |
| US-D5 Receive a ride request | [IMPLEMENTED] `ride.offer` real but carries `ride_id` only | — n/a | ⚪ not created — planned: offer + detail fetch (M4) |
| US-D6 Accept the ride | [PARTIAL] WS accept/decline real; HTTP decline **stub** | — n/a | ⚪ not created — planned: accept/decline (M5) |
| US-D7 Navigate to the pickup | [IMPLEMENTED] pgRouting | — n/a | ⚪ not created — planned: nav screen (M6) |
| US-D8 Arrived at pickup | [PARTIAL] status transition real; notify-arrival **stub** | — n/a | ⚪ not created — planned: arrival button (M7) |
| US-D9 Start and complete the trip | [IMPLEMENTED] state machine enforced | — n/a | ⚪ not created — planned: trip journey (M7) |
| US-D10 Rate the rider | [IMPLEMENTED] rating persisted | — n/a | ⚪ not created — planned: rating screen (M8) |
| US-D11 View history & earnings | [PARTIAL] history + current real; earnings/withdraw **stub** | — n/a | ⚪ not created — planned: earnings, derived client-side (M9) |

### Endpoint counts (whole API, from `internal/router/router.go`)

- **79 HTTP routes** registered (incl. `/docs` redirect + `/docs/*any`); WS at `/ws`. One emblem of the state: the single `StubPayment` handler (`handler/platform.go:374`) backs **20** of them.
- Per-route status: **39 [IMPLEMENTED]** · **2 [PARTIAL]** (`auth/verify-email`, `auth/verify-phone`) · **36 [STUB]** (the 2 `/docs` routes just serve the spec).
- 4 [PARTIAL] stories (US-3, US-13, US-16, US-D8): real endpoints with a stubbed sub-resource, except US-16 whose only gap is the missing server push.
- **App tier:** the rider app actually wires **~12 endpoints** (see Appendix); the rest are declared-but-unused or faked in-app. Recompute after each build plan lands (`rider_app_plans/` 02–07 wire ~8 more). The driver app is **0/76** today (not created).
- Full per-route matrix (API + Rider app + Driver app) in the **Appendix**.

---

## Conventions

- Base URL: `http://<host>:8080`; API routes live under `/api/v1`.
- Auth: `Authorization: Bearer <access_token>` on every protected call.
- Real-time: `GET /ws` (Bearer-token authenticated WebSocket). The backend pushes `ride.offer`, `ride.updated`, and `driver.location` events; the app replies with `ping` / `ride.accept` / `ride.decline`.
- Booking safety: `POST /api/v1/rides` supports replay protection via the optional `Idempotency-Key` header. **Caveat (v2):** dedupe works (repeat key returns the stored status + an **empty body**), but there is a race window for concurrent same-key requests and no automated test covers it. See US-5.
- Role checks: rider endpoints require the `rider` role, driver endpoints the `driver` role (accounts are promoted via `POST /api/v1/driver/register`).
- Trip state machine: `pending → accepted → driver_arrived → in_progress → completed`; `cancelled` is allowed from `pending`, `accepted`, and `driver_arrived`; `pending → no_driver_available` when dispatch fails. Every state change is echoed to both sides as a `ride.updated` event (`internal/service/ride.go:24-31`).

---

# Part A — Rider app (the passenger)

## US-1 Sign up **[IMPLEMENTED]**
- **App status:** Rider app 🟡 partial (register wired; forgot-password screen is fake, verify ⚪) · Driver app — n/a
**As a** new rider, **I want** to create an account with my email/phone/password, **so that** I can book rides.

- **Screen:** Onboarding / Register
- **API:**
  - `POST /api/v1/auth/register` — body `{email, phone, password}` → `201 {user:{id,email,phone,role:"rider"}}`
  - `POST /api/v1/auth/forgot-password` and `POST /api/v1/auth/reset-password` — real flows (DB reset token, token reuse rejected)
  - `POST /api/v1/auth/verify-email` and `POST /api/v1/auth/verify-phone` — **[PARTIAL]**: they *do* set `email_verified`/`phone_verified = true`, but the submitted verification `code` is **ignored** (`_ = code`).
- **Notes:** Register always creates the `rider` role and a rider profile. After this the app proceeds to US-2.
- **Code state:** `handler/auth.go:62-87` (real), `service/auth.go:39-63`; forgot/reset `handler/auth.go:209-261`; verify stubs `handler/auth.go:274-325`, `service/auth.go:249-267`.
- **Acceptance:** register posts `POST /auth/register` and proceeds to US-2; forgot/reset post the real endpoints (AC-1); verify-email/phone stay ⚪ until the backend validates the submitted code.

## US-2 Log in **[IMPLEMENTED]**
- **App status:** Rider app 🟡 partial (login/logout wired; auto-refresh defined but never triggered) · Driver app — n/a
**As a** rider, **I want** to log in and receive tokens, **so that** I can call authenticated endpoints and open a WebSocket.

- **Screen:** Login
- **API:**
  - `POST /api/v1/auth/login` — body `{email, password}` → `200 {access_token, refresh_token, user}`
  - `POST /api/v1/auth/refresh` — body `{refresh_token}` → new token pair when it expires; rotates and rejects reuse
  - `POST /api/v1/auth/logout` — body `{refresh_token}` on sign-out
- **Notes:** Store tokens securely; attach `Authorization: Bearer` to all subsequent calls.
- **Code state:** `handler/auth.go:105-196`, `service/auth.go:65-133`. Covered by `tests/auth_test.go`.
- **Acceptance:** login/logout round-trip persists tokens; a mid-session 401 auto-refreshes once, otherwise logs out (AC-3).

## US-3 Set pickup & destination **[PARTIAL]**
- **App status:** Rider app 🟡 partial (autocomplete/search wired; no reverse-geocode — manual address entry) · Driver app — n/a
**As a** rider, **I want** to enter or search my destination and confirm my pickup, **so that** the app knows where to send the driver.

- **Screens:** Home (map) / Search
- **API:**
  - `PUT /api/v1/geo/rider/location` — body `{lat, lng}` → `204` (broadcast current position)
  - `GET /api/v1/places/autocomplete?lat=&lng=&q=&radius=&limit=` — **real** PostGIS + full-text search over OSM-seeded places → `{places:[...]}`
  - `GET /api/v1/places/geocode?lat=&lng=` — **[STUB]** (returns `{"place":null}`)
  - `GET /api/v1/places/details?id=` — **[STUB]** (returns `{"place":null}`)
- **Notes:** Autocomplete works against a real `places` table seeded from OSM and is production-usable. Geocode (map pin → address) and details are still stubs — fall back to manual address entry until then.
- **Code state:** rider location `handler/geo.go:117-127`; autocomplete `handler/platform.go:156-202` + `repository/places_repo.go:26-44`; geocode/details stubs `handler/platform.go:211-224`. Covered by `tests/routing_test.go`.
- **Acceptance:** autocomplete results render from real search; pickup coordinates captured; position streamed via `PUT /geo/rider/location` (GEO-1); geocode/details stay blocked (backend STUB).

## US-4 See the price & ETA estimate **[IMPLEMENTED]**
- **App status:** Rider app 🟡 partial (price wired → renders live backend quotes; `eta` endpoint still unused) · Driver app — n/a
**As a** rider, **I want** to preview the fare and ETA before confirming, **so that** I can decide whether to book.

- **Screen:** Confirm / Estimate
- **API:**
  - `GET /api/v1/estimates/price?pickup_lat&pickup_lng&dropoff_lat&dropoff_lng[&vehicle_type]` → `{estimates:[{vehicle_type, base_fare, distance_rate, time_rate, distance_fare, time_fare, surge_multiplier, total}]}` — computed by the real fare engine (base + distance + time + surge) from a pgRouting route
  - `GET /api/v1/estimates/eta?from_lat&from_lng&to_lat&to_lng` → `{eta_seconds, distance_meters}` — route-based travel time before booking
  - `GET /api/v1/geo/eta` (same params) → voyage-computed; the matching driver's arrival ETA is also pushed live on accept: `ride.updated` carries real `eta_seconds` (driver position → pickup, US-6)
- **Notes:** The fare engine (`FareService.CalculateEstimate`: base + distance + time + surge over real pgRouting, `internal/service/fare.go`) is now wired into `estimates/price`. `eta_seconds: 300` is no longer hardcoded — `geo/eta` + `estimates/eta` compute route-based ETA, and the accept payload computes driver→pickup ETA.
  - **Rate card is a deliberate code constant** (`service/fare.go:68-83`): the quoted fare is snapshotted onto the ride at booking, nothing edits the tariff at runtime, and `vehicle_type` is a closed enum — a DB `fare_rates` table would add infra with no behavior change. Revisit (move to a versioned DB table) when real GPS-time/distance completion fares, earnings/withdraw, or per-region/time-of-day pricing land.
- **Code state:** `handler/platform.go:279` (price), `handler/platform.go:334` (eta); dispatch ETA `service/dispatch.go:160`; rates `service/fare.go:81`. Covered by `tests/routing_test.go` (TestEstimates, TestGeoETA) and `tests/ride_lifecycle_test.go` (accept `eta_seconds`).
- **Acceptance:** price renders the live response (no client-side fakes); ETA values render wherever surfaced (LC-4).

## US-5 Request the trip **[IMPLEMENTED]**
- **App status:** Rider app 🟢 wired (POST /rides + idempotency-key reuse per attempt) · Driver app — n/a
**As a** rider, **I want** to confirm the ride, **so that** nearby drivers are dispatched to my pickup.

- **Screen:** Confirm ride
- **API:**
  - `POST /api/v1/rides` — optional header `Idempotency-Key: <uuid>` (replay protection), body `{pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, pickup_address, dropoff_address, vehicle_type}` → `201 {ride:{..., status:"pending"}}`
  - WebSocket: server pushes `ride.updated` with `status:"pending"` (+ pickup/dropoff) to the rider's `/ws` connection.
- **Notes:** Fare is calculated server-side from the real route (base + distance + time + surge, surge from driver count within 2 km). Retries should reuse the same `Idempotency-Key`.
  - **Idempotency caveat [PARTIAL]:**
    - Repeat key → correct status code returned, but the stored `response_body` is `{}`, so the replay returns an **empty body** (not the original ride).
    - No unique `(user, key)` guard: two concurrent same-key requests can both create a ride.
    - No automated test covers the header.
- **Code state:** create `handler/ride.go:59-90` + `service/ride.go:33-89`; fare `service/fare.go:27-77` (surge `52-66`); idempotency middleware `middleware/idempotency.go:11-45`.

## US-6 Wait for a driver **[IMPLEMENTED]**
- **App status:** Rider app 🟡 partial (WS receive wired, but listens for invented `ride_matched`/`driver_moved`/`ride_arrived`/`ride_completed` — so accepted/cancelled/not-found states are broken) · Driver app — n/a
**As a** rider, **I want** to see the searching state and driver availability, **so that** I know the request is live.

- **Screen:** Searching for driver
- **API:**
  - WebSocket: keep `/ws` open; watch for `ride.updated` → `status:"accepted"` or `status:"no_driver_available"`.
  - `GET /api/v1/rides/current` → `{ride|null}` (poll fallback if WS drops)
- **Notes:** The backend dispatches within expanding radii `{500, 1000, 2000, 5000, 10000} m`, offering to at most **5** drivers, waiting up to **30 s** per driver, and only delivering offers to drivers with a **live `/ws` connection** (`hub.IsConnected`).
  - **Behavior nuance:** at each larger radius the query still returns the same nearest ≤5 drivers (ordered by distance), so the same driver may be re-offered across radii; worst case is 5 radii × 5 sequential attempts, not 25 fresh drivers.
  - If no driver accepts, the ride becomes `no_driver_available`.
- **Code state:** `service/dispatch.go` (radii `:42`, `maxLimit=5` `:43`, 30 s `:107`, WS-gated `:82-85`, sequential loop `:62-107`). Indirectly covered by `tests/ride_lifecycle_test.go` (decline path); **no direct `no_driver_available` test exists**.
  - **WS silence:** offer delivery and status pushes require a live `/ws`; during long searches (worst case 5 radii × 30 s) the client may receive nothing — the matching UI must not fake a timeout and must rely on `GET /rides/current` for the final outcome.
- **Acceptance:** the searching state stays honest during long silent matches (no fake timeout); "no driver" is detected via the `GET /rides/current` poll (LC-2).

## US-7 Track the matched driver **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (driverLocation declared-but-unused; active-ride screen reads invented keys like `driver_lat`/`driver_name`) · Driver app — n/a
**As a** rider, **I want** to see my driver's info, vehicle, and live location, **so that** I know who is coming and when.

- **Screen:** Driver on the way
- **API:**
  - WebSocket: `ride.updated` → `status:"accepted"` carries `driver {id, first_name, photo_url, rating, vehicle, location}`.
  - WebSocket: `driver.location` events stream the driver's position during the trip.
  - `GET /api/v1/drivers/:id/location` → `{lat, lng, heading, speed, ...}` (polling fallback, **real PostGIS query**)
- **Notes:**
  - Live driver telemetry is only pushed while the driver is streaming `PUT /api/v1/geo/driver/location`.
  - `eta_seconds` in the accept payload is computed from the driver's live position → pickup via the routing engine (`service/dispatch.go:160-208`).
  - The driver `rating` payload is unreliable: `service/dispatch.go:156` does `strconv.ParseFloat(driver.RatingSummary, 64)` but the column stores JSON `{"average":0,"count":0}` — the parse fails and rating comes through as `0.0`.
- **Code state:** accept broadcast `service/dispatch.go:132-205`; location stream `handler/geo.go:42-76` + `repository/geo_repo.go:30-47`; polling fallback `handler/geo.go:186-194`.
- **Acceptance:** the driver card + marker render from the typed `accepted` payload; live moves come from `driver.location` with `GET /drivers/:id/location` as fallback; rating `0.0` displays as "New"; no invented keys like `driver_lat`/`driver_name` remain (LC-4).

## US-8 Ride in progress **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (no route fetch; relies on the broken WS keys) · Driver app — n/a
**As a** rider, **I want** to follow the trip and see the route, **so that** I can plan my time and feel informed.

- **Screen:** Active trip
- **API:**
  - WebSocket: `ride.updated` → `status:"driver_arrived"`, then `status:"in_progress"`.
  - `GET /api/v1/navigation/route?from_lat=&from_lng=&to_lat=&to_lng=` → `{polyline, total_distance_m, total_duration_s}` — **real pgRouting Dijkstra**
  - `GET /api/v1/rides/:id` → full ride object (authoritative state)
- **Notes:**
  - Route duration is approximated as `distance / 11` (≈ 40 km/h constant), not true travel-time routing (`service/navigation.go:42-43`).
  - `PUT /api/v1/rides/:id/destination` (change destination / add a stop mid-trip) is **[STUB]** — returns `"destination updated"` but never touches the ride row.
- **Code state:** route `handler/platform.go:277-308`, `repository/navigation_repo.go:32-64`; destination stub `handler/platform.go:261-263`. Covered by `tests/navigation_test.go`.
- **Acceptance:** the active trip renders the route polyline from `GET /navigation/route` and tracks `driver.location` while in progress (LC-4).

## US-9 Trip complete & fare **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (receipt declared-but-unused) · Driver app — n/a
**As a** rider, **I want** to see the final fare breakdown when the trip ends, **so that** I can review charges.

- **Screen:** Fare / Receipt
- **API:**
  - WebSocket: `ride.updated` → `status:"completed"` includes `fare {base_fare, distance_fare, time_fare, surge_multiplier, total}`.
  - `GET /api/v1/rides/:id/receipt` → `{receipt:{base_fare, distance_fare, time_fare, surge_multiplier, total}}` — durable, DB-backed
- **Notes:**
  - **The "actual-trip multiplier" is NOT real:** on completion the fare is inflated by a hard-coded **1.1×** (`ride.TotalFare * 1.1`) with a comment saying real distance/time would normally come from GPS logs (`service/ride.go:166-169`). Distance/time fare components are *not* recomputed.
- **Code state:** `service/ride.go:158-190`; receipt `handler/ride.go:330-347`. Covered by `tests/ride_lifecycle_test.go`.
- **Acceptance:** completion surfaces the WS `fare` breakdown, backed by `GET /rides/:id/receipt` (LC-3).

## US-10 Rate the driver **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (rateRide declared-but-unused) · Driver app — n/a
**As a** rider, **I want** to rate and optionally comment on the driver after the trip, **so that** the community gets better service.

- **Screen:** Rating
- **API:**
  - `POST /api/v1/rides/:id/rate` — body `{score: 1..5, comment}` → `200 {message:"rating submitted"}`
- **Notes / gaps [PARTIAL]:**
  - Rating rows are **persisted** in the `ratings` table.
  - No check that the ride is `completed`, and no check that the rater is a party to the ride.
  - The read-back endpoints `GET /api/v1/rider/ratings` / `GET /api/v1/driver/ratings` are **[STUB]**.
  - `drivers.rating_summary` is **never recalculated**, so aggregate ratings never reflect new ratings.
- **Code state:** `handler/ride.go:258-293` → `service/ride.go:192-207` → `repository/ride_repo.go:177-183`.
- **Acceptance:** rating posts `POST /rides/:id/rate` with a double-submit guard (LC-3).

## US-11 Cancel a ride **[IMPLEMENTED]**
- **App status:** Rider app ❌ stubbed (no API call — a 1s mock in `active_ride_screen.dart:44`; cancelRide declared-but-unused) · Driver app — n/a
**As a** rider, **I want** to cancel before the driver picks me up, **so that** I can change plans.

- **Screen:** Any pre-trip screen
- **API:**
  - `POST /api/v1/rides/:id/cancel` → `200 {ride:{status:"cancelled"}}`
  - WebSocket: both rider and driver receive `ride.updated` → `status:"cancelled"` with `cancelled_by:"rider"`.
- **Notes:**
  - Only allowed in `pending`, `accepted`, or `driver_arrived` (state machine enforced server-side).
  - The driver also has a real cancel path: `POST /api/v1/driver/rides/:id/cancel`.
  - `cancellation_fee` exists on the model + DB column but is **never computed or charged**.
- **Code state:** `service/ride.go:91-131`; driver-side cancel `handler/ride.go:200-211`. Covered by `tests/ride_lifecycle_test.go`, `tests/ws_push_test.go`.
- **Acceptance:** cancel posts `POST /rides/:id/cancel` (no 1 s mock); WS `cancelled` returns to Home; the fee is never charged (backend gap) (LC-1).

## US-12 Safety — send an SOS **[STUB]**
- **App status:** Rider app ⚪ not implemented (sos declared-but-unused) · Driver app — n/a
**As a** rider, **I want** to trigger an emergency alert from the trip screen, **so that** help can be dispatched if something goes wrong.

- **Screen:** Safety / SOS
- **API:**
  - `POST /api/v1/sos` — body `{lat, lng}` → `201 {message, alert:{...}}`
- **Notes:** Returns an acknowledgment and echoes the payload with `status:"active"`, but **nothing is persisted or dispatched**. The `sos_alerts` DB table exists but no code writes to it. Test only asserts the 201 ack.
- **Code state:** `handler/platform.go:50-67`; unused table in migration `007_create_misc.up.sql:49-60`; test `tests/cross_cutting_test.go:26-46`.
- **Acceptance:** SOS posts with the last known position; the UI states "acknowledged only" (SAF-1, plan 07).

## US-13 Profile & devices **[PARTIAL]**
- **App status:** Rider app 🟡 partial (GET /rider/me used for auth check; ProfileScreen is hardcoded "Rider"/"rider@example.com"; PUT /rider/me + devices ⚪) · Driver app — n/a
**As a** rider, **I want** to view/edit my profile and register my device, **so that** my details and push notifications are correct.

- **Screens:** Profile / Settings
- **API:**
  - `GET /api/v1/rider/me` → `{user, rider}` **[IMPLEMENTED]**
  - `PUT /api/v1/rider/me` — body `{first_name, last_name, photo_url, phone?}` **[IMPLEMENTED]**
  - `PUT /api/v1/rider/me/status` — body `{status}` **[IMPLEMENTED]**
  - `DELETE /api/v1/rider/me` — soft-deletes the account **[IMPLEMENTED]**
  - `POST /api/v1/devices` — body `{token, platform}` — **[STUB]**: validates the body and replies `"device registered"` but **never writes to `device_tokens`**
  - `DELETE /api/v1/devices/:token` on app uninstall — **[STUB]**: returns 204, does nothing
- **Notes:** The profile half is fully real. Push-specific work (persist device rows, and especially a **delivery pipeline**) is all missing — see Part C.
- **Code state:** profiles `handler/rider.go:41-124`; device stubs `handler/platform.go:99-118`.
- **Acceptance:** profile renders `GET /rider/me` and persists edits via `PUT /rider/me` (AC-2); devices stay ⚪ until the push pipeline is real.

## US-14 Ride history **[IMPLEMENTED]**
- **App status:** Rider app ❌ stubbed (HistoryScreen shows a fake "No rides yet"; ridesHistory declared-but-unused) · Driver app — n/a
**As a** rider, **I want** a paginated list of past trips, **so that** I can re-book or reference them.

- **Screen:** History
- **API:**
  - `GET /api/v1/rides/history?page=1&per_page=20` → `{rides, total, page, per_page, total_pages}`
- **Code state:** `handler/ride.go:151-189` (paginated DB query). Covered by `tests/ride_lifecycle_test.go`.
- **Acceptance:** history is a paginated list from `GET /rides/history` with infinite scroll (LC-5, plan 04).

## US-15 View the fare receipt **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (receipt declared-but-unused; plan `rider_app_plans/03-receipt-rate-tracking.md`) · Driver app — n/a
**As a** rider, **I want** to open the fare receipt again after the trip (and from history), **so that** I can review or dispute charges.

- **Screen:** Receipt (re-openable from History)
- **API:**
  - `GET /api/v1/rides/:id/receipt` → `{receipt:{base_fare, distance_fare, time_fare, surge_multiplier, total}}` — durable, DB-backed
- **Notes:** Distinct from US-9 (fare shown at the moment of completion via WS): this is the durable receipt screen, reachable at any time after the trip ends.
- **Acceptance:** the receipt screen renders numbers from `GET /rides/:id/receipt`, not from client-side fakes (LC-3).
- **Code state:** `handler/ride.go:330-347`.

## US-16 No driver available **[PARTIAL]**
- **App status:** Rider app ⚪ not implemented (detection needs the `GET /rides/current` poll; plan `rider_app_plans/02-cancel-and-current-poll.md`) · Driver app — n/a
**As a** rider, **I want** to be told when no driver accepted my trip, **so that** I can retry or change plans.

- **Screen:** Searching / Matching
- **API:**
  - `GET /api/v1/rides/current` → `{ride|{status:"no_driver_available"}}` — the workable detection path.
  - WebSocket: `ride.updated` → `status:"no_driver_available"` would be ideal, but the backend only updates the DB row and **never pushes this event** (`service/dispatch.go:59,78`).
- **Notes:** [PARTIAL] because the reliable signal is the poll, not a push (dispatching can legitimately take up to 5 radii × 30 s — see US-6).
- **Acceptance:** when dispatch gives up, the matching UI shows "no drivers found" + a retry, driven by the `GET /rides/current` poll (LC-2).

## US-17 Re-book from history **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (ridesHistory unused; plan `rider_app_plans/04-history.md`) · Driver app — n/a
**As a** rider, **I want** to repeat a past trip with one tap, **so that** I don't re-enter addresses.

- **Screen:** History
- **API:**
  - `GET /api/v1/rides/history?page=1&per_page=20` — each ride carries its `pickup_address`/`dropoff_address`.
- **Notes:** All data needed already comes from the history endpoint.
- **Acceptance:** tapping a past ride prefills the booking form (pickup/dropoff) (LC-5).

---

# Part B — Driver app (the driver)

## US-D1 Create a driver account **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: onboarding flow, `DRIVER_APP_PLAN.md` M2)
**As a** driver, **I want** to create an account and register as a driver, **so that** I can start receiving ride requests.

- **Screens:** Onboarding → Driver registration
- **API:**
  - `POST /api/v1/auth/register` — body `{email, phone, password}` → creates the account in the `rider` role
  - `POST /api/v1/driver/register` (auth) → `201 {driver:{status:"offline", onboarding_status:"documents_submitted"}}` promotes the user to `driver`
- **Notes:** After promotion the account holds the `driver` role, so the driver app uses the driver endpoints. Document *upload/verification* endpoints are [STUB] (US-D3 / Part C).
- **Code state:** `handler/driver.go:34-49`. Covered by `tests/dispatch_test.go`.
- **Acceptance:** onboarding performs `POST /driver/register` and the account then holds the `driver` role (`DRIVER_APP_PLAN.md` M2).

## US-D2 Log in **[IMPLEMENTED]**
- **App status:** Rider app — n/a (same auth stack, see US-2) · Driver app ⚪ not created (planned: auth + 401 auto-refresh, `DRIVER_APP_PLAN.md` M1)
**As a** driver, **I want** to log in and get tokens, **so that** I can go online and connect to live offers.

- **Screen:** Login
- **API:**
  - `POST /api/v1/auth/login` → `200 {access_token, refresh_token, user}`
  - `POST /api/v1/auth/refresh` on token expiry; `POST /api/v1/auth/logout` on sign-out
- **Notes:** Same real auth stack as US-2.
- **Acceptance:** login routes to Home; a mid-session 401 auto-refreshes once (M1).

## US-D3 Set up profile & vehicle **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (vehicle/documents screens planned but feature-gated until backend is real, `DRIVER_APP_PLAN.md` M10)
**As a** driver, **I want** to add my name/photo and vehicle details, **so that** riders see who is coming for them.

- **Screen:** Profile / Vehicle
- **API:**
  - `GET /api/v1/driver/me` → `{driver:{..., vehicle}}` and `PUT /api/v1/driver/me` — body `{first_name, last_name, photo_url}` — **[IMPLEMENTED]**
  - `GET /api/v1/driver/me/vehicle` / `PUT /api/v1/driver/me/vehicle` — **[STUB]** (returns the generic stub payload; no CRUD, no persistence)
- **Notes:**
  - The *read* path used in dispatch is real: `FindVehicleByDriverID` (`repository/ride_repo.go:168-175`) feeds `driver.vehicle` into the accepted `ride.updated` payload — but there is **no real source of vehicle data** to write, and in tests a synthetic "Toyota Camry / ABC-1234" is fabricated (`tests/testutil/mock_repos.go`). This must be real before launch.
- **Code state:** profile `handler/driver.go:59-93`; vehicle stub `router.go:128-129` → `handler/platform.go:374-379`.
- **Acceptance:** profile renders `GET /driver/me`; vehicle/documents screens feature-gated until the backend is real (M10).

## US-D4 Go online **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: availability toggle + location stream + WS, `DRIVER_APP_PLAN.md` M3)
**As a** driver, **I want** to set myself online and start broadcasting my location, **so that** the dispatcher can offer me rides.

- **Screen:** Home / Availability
- **API:**
  - `PUT /api/v1/driver/me/status` — body `{status:"online"}` (use `"offline"` to stop)
  - `PUT /api/v1/geo/driver/location` — body `{lat, lng, heading, speed}` → `204` (stream periodically; batch via `PUT /api/v1/geo/driver/location/batch`)
  - `GET /ws` — open the authenticated WebSocket to receive offers
- **Notes:** Dispatch only offers rides to drivers whose `/ws` connection is live (`hub.IsConnected`), so online + WS + location must all be active.
- **Code state:** `handler/driver.go:105-117`, `handler/geo.go:42-105`, `hub.go:119-124`.
- **Acceptance:** the online toggle drives status + location stream + WS lifecycle (M3).

## US-D5 Receive a ride request **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: offer → GET /driver/rides/:id detail, `DRIVER_APP_PLAN.md` M4)
**As a** driver, **I want** to see an incoming trip offer with the key details, **so that** I can decide whether to take it.

- **Screen:** Ride offer
- **API:**
  - WebSocket: `ride.offer` → `{ride_id}` (the offer payload **only carries the id** today)
  - `GET /api/v1/driver/rides/:id` → full ride `{pickup_lat/lng/address, dropoff..., vehicle_type, status:"pending", fares}` — real, DB-backed
- **Notes:** Offer context (distance to pickup, fare, TTL) therefore requires a follow-up `GET /driver/rides/:id`. A richer offer payload is a Part C improvement.
- **Code state:** offer push `service/dispatch.go:99-102`; ride detail `handler/ride.go:130-138`.
- **Acceptance:** the offer dialog fetches `GET /driver/rides/:id` for details (M4).

## US-D6 Accept the ride **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: WS accept/decline + HTTP accept fallback, `DRIVER_APP_PLAN.md` M5)
**As a** driver, **I want** to accept a matching offer, **so that** the rider is notified and the trip moves to `accepted`.

- **Screen:** Ride offer
- **API:**
  - Primary (live): WebSocket message `ride.accept` → `{ride_id}`; wired to `DispatchService.HandleAccept` — but **requires an active offer** (`handler == no active offer` error).
  - Fallback/HTTP: `POST /api/v1/driver/rides/:id/accept` → `200 {message:"ride accepted"}` or `409` if another driver took it — **does not require an active offer**; assignment is guarded by `WHERE status='pending'`.
  - WebSocket: both driver and rider receive `ride.updated` → `status:"accepted"` with driver info + real `eta_seconds` (driver position → pickup).
- **Notes:** Declining via WebSocket `ride.decline` → `{ride_id}` works (`HandleDecline`). The HTTP `POST /api/v1/driver/rides/:id/decline` is a [STUB]. Offers expire after 30 s (dispatch timeout).
- **Code state:** hub routing `websocket/hub.go:95-110`; HTTP accept `service/dispatch.go:132-205` (conflict `handler/ride.go:305-319`); decline HTTP stub `router.go:142` → `handler/platform.go:374-379`.
- **Acceptance:** accept via WS `ride.accept` with the HTTP fallback; decline is WS-only (M5).

## US-D7 Navigate to the pickup **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: nav screen with polyline, `DRIVER_APP_PLAN.md` M6)
**As a** driver, **I want** turn-by-turn guidance to the pickup point, **so that** I arrive efficiently.

- **Screen:** Navigation
- **API:**
  - `GET /api/v1/navigation/route?from_lat=&from_lng=&to_lat=&to_lng=` → `{polyline, total_distance_m, total_duration_s}`
- **Notes:** Same real pgRouting service as US-8; duration is the `distance / 11` approximation.
- **Code state:** `handler/platform.go:277-308`.
- **Acceptance:** the nav screen renders the polyline from `GET /navigation/route` (M6).

## US-D8 Arrived at pickup **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: arrival button via PUT status, `DRIVER_APP_PLAN.md` M7)
**As a** driver, **I want** to mark that I arrived and notify the rider, **so that** the rider comes out.

- **Screen:** Arrival
- **API:**
  - `PUT /api/v1/driver/rides/:id/status` — body `{status:"driver_arrived"}` — **[IMPLEMENTED]**, state machine enforced, echoed as `ride.updated`
  - `POST /api/v1/driver/rides/:id/notify-arrival` → `200 {message}` — **[STUB]**: no push is actually sent
- **Notes:** A real "notify the rider" push depends on the missing push-delivery pipeline (Part C).
- **Code state:** status advance `handler/ride.go:225-242` → `service/ride.go:133-190`; notify-arrival stub `handler/platform.go:352-354`.
- **Acceptance:** arrival sets `driver_arrived` via `PUT /driver/rides/:id/status`; notify-arrival shown as push-gated (M7).

## US-D9 Start and complete the trip **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: single-button trip state machine, `DRIVER_APP_PLAN.md` M7)
**As a** driver, **I want** to start the trip when the rider is onboard and complete it at the destination, **so that** the fare is finalized.

- **Screen:** Active trip
- **API:**
  - `PUT /api/v1/driver/rides/:id/status` — body `{status:"in_progress"}`, then `{status:"completed"}`
  - WebSocket: both sides get `ride.updated` → `in_progress`, then `completed` (with the final `fare`).
- **Notes:** Transitions are capped by the assigned driver *role group only* — the handler checks the `driver` role but **not ride ownership** (`handler/ride.go:225-242` reads only the role), so any driver could advance any ride's status. Transitions outside the state machine are rejected with `400`. Completion applies the hard-coded 1.1× fare inflation (see US-9).
- **Code state:** `service/ride.go:133-190`; covered by `tests/ride_lifecycle_test.go`, `tests/ws_push_test.go`.
- **Acceptance:** the single-button journey drives the state machine to `completed` (M7).

## US-D10 Rate the rider **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: rating screen, `DRIVER_APP_PLAN.md` M8)
**As a** driver, **I want** to rate the rider after the trip, **so that** rider quality is tracked.

- **Screen:** Rating
- **API:**
  - `POST /api/v1/driver/rides/:id/rate` — body `{score: 1..5, comment}` → `200 {message}`
- **Notes:** Same rating persistence + gaps as US-10 (no `completed`/party check; read-back stub; summary never updated).
- **Code state:** `handler/ride.go:258-293`.
- **Acceptance:** rating posts `POST /driver/rides/:id/rate` (M8).

## US-D11 View history & earnings **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app ⚪ not created (planned: earnings derived from history, withdraw hidden, `DRIVER_APP_PLAN.md` M9)
**As a** driver, **I want** to see my ride history and earnings, **so that** I can track my income.

- **Screen:** Earnings / History
- **API:**
  - `GET /api/v1/driver/rides/history?page=1&per_page=20` → `{rides, total, page, per_page, total_pages}` — **[IMPLEMENTED]** (paginated)
  - `GET /api/v1/driver/rides/current` → `{ride|null}` — **[IMPLEMENTED]** (check active trip)
  - `GET /api/v1/driver/me/earnings` — **[STUB]**
  - `GET /api/v1/driver/rides/queue` — **[STUB]** (always `{queue:[]}`)
  - `POST /api/v1/driver/earnings/withdraw` — **[STUB]**
- **Code state:** history/current `handler/ride.go:100-189`; stubs `handler/platform.go:328-330, 374-379`, `router.go:209`.
- **Acceptance:** history + client-side earnings derived from `GET /driver/rides/history`; withdraw hidden (M9).

---

# Part C — Missing / stubbed work to build next

Everything here was re-verified against the code at `051ecaf`. API tier tags: **[STUB]** = endpoint exists but returns placeholders; **[PARTIAL]** = real with a stub/hardcoded sub-path; **[MISSING]** = no endpoint/route at all. App tier marks (Rider app / Driver app) use the legend at the top of this document. Cells repeat the Appendix matrix values so Part C is self-contained.
- **How fares are quoted:** rates are hardcoded in `service/fare.go` (deliberate — see US-4). Revisit when GPS-based completion fares or dynamic pricing land.

### Core booking trip (US-3 → US-12)

| Endpoint | API | Rider app | Driver app | Needed for |
|---|---|---|---|---|
| `GET /api/v1/places/geocode?lat=&lng=` | [STUB] | ⚪ | — n/a | Reverse-geocode a map pin to an address on the Home screen (US-3); returns `{"place":null}` (`handler/platform.go:211`) |
| `GET /api/v1/places/details?id=` | [STUB] | ⚪ | — n/a | Address/place details for a search result (US-3) |
| `GET /api/v1/estimates/price` + `GET /api/v1/estimates/eta` + `GET /api/v1/geo/eta` | [IMPLEMENTED] | 🟢 price wired (real data); eta endpoints ⚪ unused | ⚪ | Render the live price/ETA responses anywhere they are surfaced (US-4, US-6); accept-payload ETA falls back to `300` only when driver location/routing is unavailable |
| `GET /api/v1/driver/rides/:id/rider` | [STUB] | — n/a | ⚪ (planned: placeholder gated, M4) | Real rider name/rating/photo for the driver after accepting (US-D6); today returns hardcoded `{"name":"Rider","rating":5.0}` |
| `PUT /api/v1/rides/:id/destination` | [STUB] | ⚪ | ⚪ | Change destination / add a stop mid-trip (US-8); returns ack but never mutates the ride |
| `POST /api/v1/sos` | [STUB] | ⚪ declared-but-unused | ⚪ | Persist to the existing `sos_alerts` table and dispatch to emergency contacts/support (US-12) |
| `POST /api/v1/feedback` | [STUB] | ⚪ | ⚪ | Persist to the existing `feedback` table so it can be triaged |

### Payment & post-trip money

| Endpoint | API | Rider app | Driver app | Needed for |
|---|---|---|---|---|
| `POST /api/v1/rides/:id/tip` | [STUB] | ⚪ declared-but-unused | — n/a | Let the rider tip the driver (US-10) |
| `GET/POST/DELETE /api/v1/rider/payment-methods` (+ `/:id`) | [STUB] | ⚪ declared-but-unused | — n/a | Rider card/wallet management; precondition for real tipping and fare charging |
| Cancellation-fee charge | [MISSING] | ⚪ | ⚪ (fare appears on ride total once implemented) | `cancellation_fee` exists on the ride model + DB but no code ever computes/charges it (US-11) |
| `GET /api/v1/promotions`, `POST /api/v1/promotions/apply` | [STUB] | ⚪ | — n/a | Discount codes at booking (empty list / ack only) |

### Driver onboarding & money (US-D3, US-D11)

| Endpoint | API | Rider app | Driver app | Needed for |
|---|---|---|---|---|
| `GET/PUT /api/v1/driver/me/vehicle` | [STUB] | — n/a | ⚪ (planned: feature-gated, M10) | Vehicle CRUD; riders see the vehicle in `ride.updated`, and today the payload relies on a fabricated test vehicle. Must be real before launch |
| `GET/POST /api/v1/driver/me/documents` | [STUB] | — n/a | ⚪ (planned: feature-gated, M10) | Document upload + verification/approval workflow for onboarding |
| `GET /api/v1/driver/me/earnings` | [STUB] | — n/a | ⚪ (planned: derived client-side, M9) | Earnings dashboard |
| `POST /api/v1/driver/earnings/withdraw` | [STUB] | — n/a | ⚪ (planned: entry hidden, M9) | Payout requests |
| `GET /api/v1/driver/ratings` and `GET /api/v1/rider/ratings` | [STUB] | ⚪ | ⚪ | Rating breakdown screens (ratings *writes* persist; reads are stubbed and `rating_summary` is never recalculated) |

### Offers & dispatch UX

| Endpoint | API | Rider app | Driver app | Needed for |
|---|---|---|---|---|
| `POST /api/v1/driver/rides/:id/decline` | [STUB] (WS `ride.decline` works) | — n/a | ⚪ (planned: WS-only, M5) | HTTP decline with an optional reason |
| `GET /api/v1/driver/rides/queue` | [STUB] | — n/a | ⚪ (no screen planned) | Offline/missed-offer queue for drivers |
| Richer `ride.offer` payload | [MISSING] | — n/a | ⚪ (planned: offer → detail fetch, M4) | Include pickup/dropoff, fare, distance-to-pickup, and an expiry TTL so the driver can decide without a follow-up `GET /driver/rides/:id` (US-D5) |
| Accept-payload `eta_seconds` fidelity | [PARTIAL] | ⚪ (no ETA rendered today) | ⚪ (ETA from accept payload / computed client-side, M6) | Real driver→pickup route ETA, but falls back to `300` when driver location/routing is unavailable (`service/dispatch.go:160-184`) |

### Account & engagement (nice-to-have)

| Endpoint | API | Rider app | Driver app | Needed for |
|---|---|---|---|---|
| `GET/POST/DELETE /api/v1/rider/favorites` (+ `/:id`) | [STUB] | ⚪ | — n/a | Saved places for one-tap booking |
| `GET/PUT /api/v1/rider/me/preferences` | [STUB] | ⚪ | — n/a | Rider preferences |
| `POST /api/v1/auth/social` | [STUB] | ⚪ | ⚪ | Google/Apple OAuth sign-in (US-1/US-D1) |
| `POST /api/v1/auth/verify-email` / `verify-phone` | [PARTIAL] | ⚪ | ⚪ | Actually validate the submitted code instead of ignoring it |
| `GET /api/v1/geo/isochrone`, `GET /api/v1/heatmap` | [STUB] | — n/a | ⚪ | Demand analytics for drivers |
| Push delivery pipeline | [MISSING] (device register/unregister are also [STUB]) | ⚪ devices not wired | ⚪ (offers only while `/ws` open) | Actually delivering `notify-arrival` and ride updates when the app is backgrounded |

### Cross-cutting gaps

| Gap | API | Rider app | Driver app |
|---|---|---|---|
| Ride offers only delivered while the driver keeps `/ws` open | [IMPLEMENTED] (dispatch gate, `hub.IsConnected`) | — n/a | ⚪  (plan pins WS + location lifecycle to the online toggle, M3) |
| No admin endpoints (SOS triage, document verify, feedback review) | [MISSING] | — n/a | — n/a (admin/support tooling, not an app surface) |
| Idempotency-Key incomplete (empty-body replay, no concurrent guard, untested) | [PARTIAL] | 🟡 retries reuse the key but a replay returns an empty body the app must tolerate | — n/a |
| Real completion fare (hard-coded 1.1× multiplier) | [PARTIAL] | ⚪ (receipt unused today) | ⚪ (fare shown = inflated estimate) |
| Rating aggregate never recalculated (`rating_summary` stale, WS parses to `0.0`) | [PARTIAL] | ⚪ | ⚪ (driver rating shown from `rating_summary`) |

---

# Appendix — full endpoint × app status matrix

Legend — API tier: ✅ `[IMPLEMENTED]` · 🟡 `[PARTIAL]` · ❌ `[STUB]`. App tier: 🟢 wired · 🟠 wired–stub · 🟡 partial · ❌ stubbed · ⚪ not implemented · — n/a (see the Status legend).

| Method | Path | API | Rider app | Driver app | Handler | Code ref |
|---|---|---|---|---|---|---|
| GET | `/health` | ✅ | ⚪ | ⚪ | Health.Liveness | `handler/health.go:25` |
| GET | `/health/ready` | ✅ | ⚪ | ⚪ | Health.Readiness (DB ping) | `handler/health.go:37` |
| GET | `/api/v1/version` | ✅ | ⚪ | ⚪ | Platform.Version (`0.1.0`) | `handler/platform.go:362` |
| POST | `/api/v1/auth/register` | ✅ | 🟢 | ⚪ | Auth.Register | `handler/auth.go:62` |
| POST | `/api/v1/auth/login` | ✅ | 🟢 | ⚪ | Auth.Login | `handler/auth.go:105` |
| POST | `/api/v1/auth/refresh` | ✅ | 🟡 defined, never auto-triggered (AC-3 will flip) | ⚪ | Auth.Refresh (rotation + reuse rejection) | `handler/auth.go:144` |
| POST | `/api/v1/auth/logout` | ✅ | 🟢 | ⚪ | Auth.Logout | `handler/auth.go:179` |
| POST | `/api/v1/auth/forgot-password` | ✅ | ⚪ declared-but-unused; screen fake | ⚪ | Auth.ForgotPassword | `handler/auth.go:209` |
| POST | `/api/v1/auth/reset-password` | ✅ | ⚪ | ⚪ | Auth.ResetPassword | `handler/auth.go:244` |
| POST | `/api/v1/auth/verify-email` | 🟡 | ⚪ | ⚪ | sets verified, ignores code | `handler/auth.go:274` |
| POST | `/api/v1/auth/verify-phone` | 🟡 | ⚪ | ⚪ | sets verified, ignores code | `handler/auth.go:306` |
| POST | `/api/v1/auth/social` | ❌ | ⚪ | ⚪ | Auth.SocialLogin | `handler/auth.go:337` |
| GET | `/api/v1/rider/me` | ✅ | 🟢 auth-check | — | Rider.GetProfile | `handler/rider.go:41` |
| PUT | `/api/v1/rider/me` | ✅ | ⚪ never declared | — | Rider.UpdateProfile | `handler/rider.go:65` |
| PUT | `/api/v1/rider/me/status` | ✅ | ⚪ never declared | — | Rider.UpdateStatus | `handler/rider.go:98` |
| DELETE | `/api/v1/rider/me` | ✅ | ⚪ | — | Rider.DeleteAccount (soft) | `handler/rider.go:120` |
| GET | `/api/v1/rider/me/preferences` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| PUT | `/api/v1/rider/me/preferences` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/rider/ratings` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/rider/favorites` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| POST | `/api/v1/rider/favorites` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| DELETE | `/api/v1/rider/favorites/:id` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/rider/payment-methods` | ❌ | ⚪ declared-but-unused | — | StubPayment | `handler/platform.go:374` |
| POST | `/api/v1/rider/payment-methods` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| DELETE | `/api/v1/rider/payment-methods/:id` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:374` |
| POST | `/api/v1/driver/register` | ✅ | — | ⚪ | Driver.Register | `handler/driver.go:34` |
| GET | `/api/v1/driver/me` | ✅ | — | ⚪ | Driver.GetProfile | `handler/driver.go:59` |
| PUT | `/api/v1/driver/me` | ✅ | — | ⚪ | Driver.UpdateProfile | `handler/driver.go:79` |
| PUT | `/api/v1/driver/me/status` | ✅ | — | ⚪ | Driver.UpdateStatus | `handler/driver.go:105` |
| GET | `/api/v1/driver/me/documents` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| POST | `/api/v1/driver/me/documents` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/driver/me/vehicle` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| PUT | `/api/v1/driver/me/vehicle` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/driver/me/earnings` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/driver/ratings` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| GET | `/api/v1/driver/rides/current` | ✅ | — | ⚪ | Ride.GetCurrentRide | `handler/ride.go:100` |
| GET | `/api/v1/driver/rides/history` | ✅ | — | ⚪ | Ride.GetRideHistory | `handler/ride.go:151` |
| GET | `/api/v1/driver/rides/queue` | ❌ | — | ⚪ | Platform.DriverRideQueue | `handler/platform.go:328` |
| GET | `/api/v1/driver/rides/:id` | ✅ | — | ⚪ | Ride.GetRideByID | `handler/ride.go:130` |
| GET | `/api/v1/driver/rides/:id/rider` | ❌ | — | ⚪ | Platform.DriverRiderInfo (hardcoded) | `handler/platform.go:340` |
| POST | `/api/v1/driver/rides/:id/accept` | ✅ | — | ⚪ | Ride.AcceptRide (409 conflict) | `handler/ride.go:305` |
| POST | `/api/v1/driver/rides/:id/decline` | ❌ | — | ⚪ | StubPayment (WS decline works) | `handler/platform.go:374` |
| PUT | `/api/v1/driver/rides/:id/status` | ✅ | — | ⚪ | Ride.AdvanceStatus | `handler/ride.go:225` |
| POST | `/api/v1/driver/rides/:id/cancel` | ✅ | — | ⚪ | Ride.CancelRide | `handler/ride.go:200` |
| POST | `/api/v1/driver/rides/:id/rate` | ✅ | — | ⚪ | Ride.RateRide | `handler/ride.go:258` |
| POST | `/api/v1/driver/rides/:id/notify-arrival` | ❌ | — | ⚪ | Platform.ArrivalNotification | `handler/platform.go:352` |
| PUT | `/api/v1/geo/driver/location` | ✅ | — | ⚪ | Geo.UpdateDriverLocation | `handler/geo.go:42` |
| PUT | `/api/v1/geo/driver/location/batch` | ✅ | — | ⚪ | Geo.UpdateDriverLocationBatch | `handler/geo.go:88` |
| PUT | `/api/v1/geo/rider/location` | ✅ | ⚪ never declared | — | Geo.UpdateRiderLocation | `handler/geo.go:117` |
| GET | `/api/v1/geo/nearby-drivers` | ✅ | ⚪ provider fetches, never rendered → dead code | ⚪ | Geo.GetNearbyDrivers | `handler/geo.go:143` |
| GET | `/api/v1/geo/eta` | ✅ | ⚪ declared-but-unused | ⚪ | Platform.EstimatesETA (route-based) | `handler/platform.go:334` |
| GET | `/api/v1/geo/isochrone` | ❌ | ⚪ | ⚪ | StubPayment | `handler/platform.go:374` |
| POST | `/api/v1/rides` | ✅ | 🟢 | — | Ride.CreateRide (rider only, idempotency) | `handler/ride.go:59` |
| GET | `/api/v1/rides/current` | ✅ | ⚪ declared-but-unused | ⚪ | Ride.GetCurrentRide | `handler/ride.go:100` |
| GET | `/api/v1/rides/history` | ✅ | ⚪ declared-but-unused; fake screen | ⚪ | Ride.GetRideHistory | `handler/ride.go:151` |
| GET | `/api/v1/rides/:id` | ✅ | ⚪ declared-but-unused | ⚪ | Ride.GetRideByID | `handler/ride.go:130` |
| GET | `/api/v1/rides/:id/receipt` | ✅ | ⚪ declared-but-unused | — | Ride.GetRideReceipt | `handler/ride.go:330` |
| POST | `/api/v1/rides/:id/cancel` | ✅ | ❌ 1s in-app mock | ⚪ | Ride.CancelRide (`cancelled_by`) | `handler/ride.go:200` |
| POST | `/api/v1/rides/:id/rate` | ✅ | ⚪ declared-but-unused | — | Ride.RateRide | `handler/ride.go:258` |
| POST | `/api/v1/rides/:id/tip` | ❌ | ⚪ declared-but-unused | — | Ride.TipDriver | `handler/ride.go:357` |
| PUT | `/api/v1/rides/:id/destination` | ❌ | ⚪ | ⚪ | Platform.UpdateDestination | `handler/platform.go:261` |
| GET | `/api/v1/navigation/route` | ✅ | ⚪ | ⚪ | Platform.NavigationRoute (pgRouting) | `handler/platform.go:277` |
| GET | `/api/v1/places/autocomplete` | ✅ | 🟢 | ⚪ | Platform.PlacesAutocomplete (PostGIS+FTS) | `handler/platform.go:156` |
| GET | `/api/v1/places/geocode` | ❌ | ⚪ | ⚪ | Platform.PlacesGeocode | `handler/platform.go:211` |
| GET | `/api/v1/places/details` | ❌ | ⚪ | ⚪ | Platform.PlacesDetails | `handler/platform.go:222` |
| GET | `/api/v1/estimates/price` | ✅ | 🟢 wired (real fare data) | — | Platform.EstimatesPrice (fare engine) | `handler/platform.go:279` |
| GET | `/api/v1/estimates/eta` | ✅ | ⚪ | ⚪ | Platform.EstimatesETA (route-based) | `handler/platform.go:334` |
| GET | `/api/v1/promotions` | ❌ | ⚪ | ⚪ | Platform.PromotionsList (empty) | `handler/platform.go:127` |
| POST | `/api/v1/promotions/apply` | ❌ | ⚪ | ⚪ | Platform.ApplyPromotion | `handler/platform.go:138` |
| POST | `/api/v1/sos` | ❌ | ⚪ declared-but-unused | ⚪ | Platform.SOS (ack only) | `handler/platform.go:50` |
| POST | `/api/v1/feedback` | ❌ | ⚪ | ⚪ | Platform.Feedback (ack only) | `handler/platform.go:79` |
| POST | `/api/v1/devices` | ❌ | ⚪ | ⚪ | Platform.DeviceRegister (no persistence) | `handler/platform.go:99` |
| DELETE | `/api/v1/devices/:token` | ❌ | ⚪ | ⚪ | Platform.DeviceUnregister | `handler/platform.go:116` |
| GET | `/api/v1/heatmap` | ❌ | ⚪ | ⚪ | Platform.Heatmap (placeholder PNG) | `handler/platform.go:317` |
| GET | `/api/v1/drivers/:id/location` | ✅ | ⚪ declared-but-unused | — | Geo.GetDriverLocation | `handler/geo.go:186` |
| POST | `/api/v1/driver/earnings/withdraw` | ❌ | — | ⚪ | StubPayment | `handler/platform.go:374` |
| GET | `/ws` | ✅ | 🟡 receive wired; event-name contract misaligned | ⚪ | WebSocket hub (offer/updated/location; accept/decline/ping) | `websocket/hub.go` |
| GET | `/docs`, `/docs/*any` | — | ⚪ | ⚪ | Swagger UI (spec source) | `router.go:220` |

**Rider app wiring summary (from `rider_app/lib`, commit `051ecaf`):** actually invoked in code: `/auth/register`, `/auth/login`, `/auth/logout`, `/auth/refresh` (method defined, no 401 interceptor triggers it), `GET /rider/me` (auth check), `GET /geo/nearby-drivers` (provider, never rendered → dead), `GET /estimates/price`, `GET /places/autocomplete`, `POST /rides`, `/ws`. Declared in `endpoints.dart` but never invoked: forgot-password, eta, currentRide, rideById, cancelRide, rateRide, tipRide, receipt, driverLocation, paymentMethods, ridesHistory, sos. Fake UI instead of real calls: forgot-password screen, HistoryScreen ("No rides yet"), PaymentScreen ("coming soon"), SecurityScreen, ProfileScreen (hardcoded), `_cancelRide` (1s mock).

**Driver app wiring summary:** 0 of 76 app-relevant endpoints wired — `driver_app/` does not exist yet; build plan in `DRIVER_APP_PLAN.md` (P0–P6).

**Matrix freshness:** last-applied: none — plans 01–07 pending. An endpoint cell flips to 🟢/🟠 only after its build plan merges and `flutter test` passes. Update the "~12 endpoints" count and any story tags together at that point.