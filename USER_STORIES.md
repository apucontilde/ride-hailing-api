# Ride-Hailing App User Stories — v4

Two companion apps — a **Rider app** (passenger) and a **Driver app** — both talk to the same backend (`ride-hailing-api`). This document walks the full journey of one rider booking a trip and one driver receiving and accepting that trip, expressed as concise user stories. Every API call references the OpenAPI spec at `docs/swagger.json` (browseable at `/docs`), which is the source of truth for request/response schemas.

**Version 4** — re-audited against the working tree on top of commit `8a3a13f` (`feat: routing`, 2026-09-11) plus the uncommitted app work that landed since v3 (rider plans 01–11; driver_app_plans 01–03 landed, 04/06 partial, 05/07 design-only). Every story carries a status tag and a *code state* note that points at the exact implementation so the tag is verifiable and stays honest when the code moves. Each story states a **status on all three axes** — backend API, Rider app, and Driver app — per story and per endpoint (legend below; full per-endpoint matrix in the Appendix). App-tier facts were audited against `rider_app/` (build plans 01–11 landed since the v2 audit) and `driver_app/` (bootstrap scaffold + plans 01–03 landed since v3, 04/06 partial, 05/07 pending).

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
| ⚪ not implemented | The story/endpoint is not created yet, or it is declared but never invoked in the app code. |
| — n/a | The endpoint/story does not apply to that app (e.g. driver-only endpoints for the rider app). |

### Decision rule (how each status was chosen)

- A story tag (`[IMPLEMENTED]` / `[PARTIAL]` / `[STUB]`) **always refers to the backend API tier**; the app tiers are stated separately on the same line. A `[PARTIAL]`/`[STUB]` tag does **not** imply the app is broken — check the app tier separately (e.g. US-14 is `[IMPLEMENTED]` on the API while the rider-app history is ❌ stubbed).
- App **wired to a STUB backend** → app is **🟠 wired–stub**: the call works, the data does not. No such cells today — the first ones appear when a build plan (`rider_app_plans/` / `driver_app_plans/`) wires a currently-stubbed endpoint.
- App ships a **fake screen or mock** instead of the real call → app is **❌ stubbed** (e.g. US-14 history, US-1 forgot-password).
- Backend real but the app **never invokes the endpoint** (declared or not) → app is **⚪ not implemented**.
- Backend **[STUB]** and app **⚪** → nothing to decide, both tiers agree.
- **Driver app:** the bootstrap scaffold in `driver_app/` now carries a real ride surface: `driver_app_plans/STATUS.md` (WS contract + ride-state machine, online/location loop, offer accept/decline) landed and are unit-tested; 04 (trip journey) and 06 (profile/vehicle gating) are partial; 05 (earnings/history/rating) and 07 (safety/support) are still ⚪/stub. Driver-app cells reflect what the app actually invokes and renders; the vehicle/earnings/documents surface remains stubbed or feature-gated. The milestone-level blueprint stays in `DRIVER_APP_PLAN.md` (M1–M10).
- **Matrix freshness:** an endpoint cell flips to 🟢/🟠 only after the related build plan lands and `flutter test` passes — rider-app landings are condensed in `rider_app_plans/STATUS.md` (open: `[history]`, `[geo]`, `[auth]`, `[safety]`, and `[tracking]` partial) and `driver_app_plans/` (01–05 landed, 06 partial/untested, 07 pending).

## Status summary (quick reference)

### Part A — Rider app

| Story | API | Rider app | Driver app |
|---|---|---|---|
| US-1 Sign up | [IMPLEMENTED] register + forgot/reset real; verify partial | 🟡 register wired; forgot-password screen fake; verify ⚪ | — n/a |
| US-2 Log in | [IMPLEMENTED] login / refresh (rotation) / logout | 🟢 login/logout/refresh wired; 401 auto-refresh retry active | — n/a |
| US-3 Set pickup & destination | [PARTIAL] autocomplete + reverse-geocode real; details stub | 🟡 autocomplete wired; reverse-geocode unused (manual entry) | — n/a |
| US-4 See the price & ETA | [PARTIAL] real fare engine + A\* ETA; price `distance/time_rate` fields mislabeled | 🟡 live price wired; eta endpoint ⚪ | — n/a |
| US-5 Request the trip | [IMPLEMENTED] create + dispatch; idempotency partial | 🟢 create ride + idempotency-key reuse wired | — n/a |
| US-6 Wait for a driver | [IMPLEMENTED] dispatch loop + `no_driver_available` push | 🟢 WS `ride.updated` + current-poll wired; contract realigned | — n/a |
| US-7 Track the matched driver | [IMPLEMENTED] driver.location streaming + polling real; ETA real | 🟡 WS parses typed driver/location but never renders; card reads invented keys | — n/a |
| US-8 Ride in progress | [IMPLEMENTED] A\* nav real; destination-update real | 🟢 route polyline fetched + rendered (zoom-to-fit) | — n/a |
| US-9 Trip complete & fare | [IMPLEMENTED] receipt real; completion fare echoes the booked estimate | ⚪ receipt endpoint unused | — n/a |
| US-10 Rate the driver | [IMPLEMENTED] rating persisted; read-back stub | ⚪ rate endpoint unused | — n/a |
| US-11 Cancel a ride | [IMPLEMENTED] rider + driver cancel | 🟢 real `POST /rides/:id/cancel`; no 1 s mock | — n/a |
| US-12 Send an SOS | [STUB] ack only | ⚪ sos endpoint unused | — n/a |
| US-13 Profile & devices | [PARTIAL] rider profile real; devices **persist** (server), app registration ⚪ | 🟡 GET /rider/me used for auth; profile screen hardcoded; device registration not wired in-app | — n/a |
| US-14 Ride history | [IMPLEMENTED] paginated DB query | ❌ fake "No rides yet" screen; ridesHistory unused | — n/a |
| US-15 View the fare receipt | [IMPLEMENTED] receipt real; completion fare echoes the booked estimate | ⚪ receipt unused (plan 03) | — n/a |
| US-16 No driver available | [IMPLEMENTED] `no_driver_available` pushed + poll reliable | 🟢 current-poll wired + surfaces "no drivers" | — n/a |
| US-17 Re-book from history | [IMPLEMENTED] history paginated | ⚪ not implemented (plan 04) | — n/a |

### Part B — Driver app

| Story | API | Rider app | Driver app |
|---|---|---|---|
| US-D1 Create a driver account | [IMPLEMENTED] role promotion + driver row | — n/a | 🟡 bootstrap: onboarding promotes via `POST /driver/register`; name fields not transmitted |
| US-D2 Log in | [IMPLEMENTED] same auth as rider | — n/a | 🟢 bootstrap: login/logout/refresh + forgot/reset wired |
| US-D3 Set up profile & vehicle | [PARTIAL] profile real; vehicle CRUD **stub** (read path real) | — n/a | 🟡 `GET /driver/me` rendered + `PUT /driver/me` edit wired; vehicle/documents feature-gated off |
| US-D4 Go online | [IMPLEMENTED] status + location streaming + /ws | — n/a | 🟢 online toggle (`PUT /driver/me/status`) + throttled location stream (`PUT /geo/driver/location`/`batch`) wired (plan 02) |
| US-D5 Receive a ride request | [IMPLEMENTED] `ride.offer` real but carries `ride_id` only | — n/a | 🟢 `ride.offer` → offer sheet (WS `RideStateNotifier` + `GET /driver/rides/:id` detail); single-offer policy (plan 03) |
| US-D6 Accept the ride | [PARTIAL] WS accept/decline real; HTTP decline **stub** | — n/a | 🟢 accept via WS `ride.accept` when connected, HTTP `POST /driver/rides/:id/accept` fallback (409 → "trip no longer available"); decline via WS `ride.decline` (plan 03) |
| US-D7 Navigate to the pickup | [IMPLEMENTED] A\* routing | — n/a | 🟢 `GET /navigation/route` is called on trip-screen mount and refetched past a 200 m driver move, drawing the road polyline (+ driver/pickup/dropoff markers, dashed fallback). No turn-by-turn guidance |
| US-D8 Arrived at pickup | [IMPLEMENTED] status transition + real notify-arrival (WS or push) | — n/a | 🟡 "Arrived at pickup" → `PUT /driver/rides/:id/status` `driver_arrived` on its own stage; `POST /notify-arrival` is real server-side (live WS to a connected rider, backgrounded push otherwise); the app skips it because the status transition already notifies |
| US-D9 Start and complete the trip | [IMPLEMENTED] state machine enforced | — n/a | 🟢 one stage per server status driven by a single primary button, `ride.updated` merged patch-style, cancel confirm → `POST /driver/rides/:id/cancel`, `GET /driver/rides/current` launch restore, terminal fare card + `clearRide()` |
| US-D10 Rate the rider | [IMPLEMENTED] rating persisted | — n/a | 🟢 `RateSheet` (1–5 stars + optional comment) from the post-trip receipt and per completed trip in the history list → `POST /driver/rides/:id/rate`; in-session "already rated" guard, no double submit (plan 05) |
| US-D11 View history & earnings | [PARTIAL] history + current real; earnings/withdraw **stub** | — n/a | 🟢 real `RidesHistoryScreen` (paged `GET /driver/rides/history`, pull-to-refresh, infinite scroll) with a **client-side** earnings header bucketed by completion month; withdraw stays hidden because the endpoint is a stub (plan 05) |

### Endpoint counts (whole API, from `internal/router/router.go`)

- **81 HTTP routes** registered (incl. the `/docs` redirect + `/docs/*any`); WS at `/ws`. The push wave added the `/api/v1/device-tokens` alias pair for `POST`/`DELETE`. One emblem of the state: the single `StubPayment` handler still backs many of them.
- Per-route status (push wave applied): **48 [IMPLEMENTED]** · **3 [PARTIAL]** (`auth/verify-email`, `auth/verify-phone`, `estimates/price`) · **28 [STUB]** — the 2 `/docs` routes just serve the spec. The push wave flipped `feedback`, `devices` POST/DELETE and `notify-arrival` from [STUB] to [IMPLEMENTED] and added the 2 aliases. `places/geocode` went real since v2 (reverse geocode); `estimates/price` picked up a [PARTIAL] flag because its `distance_rate`/`time_rate` response fields echo the fare totals instead of the rate card. (Rows outside the push scope were not re-audited on this pass.)
- **6 [PARTIAL] stories** (US-3, US-4, US-13, US-D3, US-D6, US-D11): real endpoints with a stubbed sub-resource or a misreported field. **1 [STUB] story:** US-12 (SOS ack only). **21 [IMPLEMENTED]** (US-D8 moved to implemented with the real `notify-arrival`).
- **App tier:** the rider app now wires **13** endpoint targets (see Appendix) — auth (incl. auto-refresh), price, autocomplete, create/cancel rides, current-ride poll, and the server route polyline; the rest are declared-but-unused or fake screens. The driver app now wires **21 of the 31 declared** endpoints (20 HTTP + `/ws`) — auth (incl. auto-refresh), onboarding, profile read + `PUT /driver/me` edit, the online/location loop, the ride offer (WS + HTTP fallback accept, decline), the `driver_arrived → in_progress → completed` journey, driver cancel, the `GET /driver/rides/current` launch restore, the paged ride history, the post-trip rating, and the server route polyline. Nothing is code-referenced-but-unreachable any more. The vehicle/safety surface stays unused or feature-gated, and the earnings endpoints stay uncalled stubs. (⚠️ an earlier audit said "18 of 31" and was off by one — it omitted `GET /driver/rides/:id`, a function-style endpoint; the count before plan 05 was 19.)
- Full per-route matrix (API + Rider app + Driver app) in the **Appendix**.

---

## Conventions

- Base URL: `http://<host>:8080`; API routes live under `/api/v1`.
- Auth: `Authorization: Bearer <access_token>` on every protected call.
- Real-time: `GET /ws` (Bearer-token authenticated WebSocket). The backend pushes `ride.offer`, `ride.updated`, and `driver.location` events; the app replies with `ping` / `ride.accept` / `ride.decline`.
- Booking safety: `POST /api/v1/rides` supports replay protection via the optional `Idempotency-Key` header. **Caveat (v3):** dedupe works (repeat key returns the stored status + an **empty body**), but there is a race window for concurrent same-key requests and no automated test covers it. See US-5.
- Role checks: rider endpoints require the `rider` role, driver endpoints the `driver` role (accounts are promoted via `POST /api/v1/driver/register`).
- Trip state machine: `pending → accepted → driver_arrived → in_progress → completed`; `cancelled` is allowed from `pending`, `accepted`, and `driver_arrived`; `pending → no_driver_available` when dispatch fails. Every state change is echoed to both sides as a `ride.updated` event (`internal/service/ride.go:25-32`).

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
- **Notes:** Register always creates the `rider` role and a rider profile. After this the app proceeds to US-2. Caveat: `forgot-password` creates a real reset-token row but **no email is actually sent** — the token is only returned in dev mode, so the flow is not end-to-end usable until an email/sms delivery path lands.
- **Code state:** `handler/auth.go:62-87` (real), `service/auth.go:39-63`; forgot/reset `handler/auth.go:209-261`; verify stubs `handler/auth.go:274-325`, `service/auth.go:249-267`.
- **Acceptance:** register posts `POST /auth/register` and proceeds to US-2; forgot/reset post the real endpoints (AC-1); verify-email/phone stay ⚪ until the backend validates the submitted code.

## US-2 Log in **[IMPLEMENTED]**
- **App status:** Rider app 🟢 wired (login/logout/refresh wired; 401 single-flight auto-refresh retry lives in `api_client.dart:46-62`) · Driver app — n/a
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
- **App status:** Rider app 🟡 partial (autocomplete/search wired; reverse-geocode unused — manual address entry) · Driver app — n/a
**As a** rider, **I want** to enter or search my destination and confirm my pickup, **so that** the app knows where to send the driver.

- **Screens:** Home (map) / Search
- **API:**
  - `PUT /api/v1/geo/rider/location` — body `{lat, lng}` → `204` (broadcast current position)
  - `GET /api/v1/places/autocomplete?lat=&lng=&q=&radius=&limit=` — **real** PostGIS + full-text search over OSM-seeded places → `{places:[...]}`
  - `GET /api/v1/places/geocode?lat=&lng=` — **real** reverse geocode: nearest place within radius (default 500 m) → `{place:{...}}` or `{"place":null}`
  - `GET /api/v1/places/details?id=` — **[STUB]** (returns `{"place":null}`)
- **Notes:** Autocomplete and reverse-geocode both work against the real `places` table seeded from OSM and are production-usable. Details are still a stub, and the rider app still uses manual address entry (its `geocode` endpoint is not even declared in `endpoints.dart`), so the /details gap has no visible impact yet.
- **Code state:** rider location `handler/geo.go:117-127`; autocomplete `handler/platform.go:156-202` + `repository/places_repo.go:26-44`; geocode `handler/platform.go:235-268` + `repository/places_repo.go:50-69` (landed `01a61c9`); details stub `handler/platform.go:278-280`. Covered by `tests/routing_test.go`.
- **Acceptance:** autocomplete results render from real search; pickup coordinates captured; position streamed via `PUT /geo/rider/location` (GEO-1); details stay blocked (backend STUB); reverse-geocode is available on the API and can be wired to the map pin (US-3).

## US-4 See the price & ETA estimate **[PARTIAL]**
- **App status:** Rider app 🟡 partial (price wired → renders live backend quotes; `eta` endpoint still unused) · Driver app — n/a
**As a** rider, **I want** to preview the fare and ETA before confirming, **so that** I can decide whether to book.

- **Screen:** Confirm / Estimate
- **API:**
  - `GET /api/v1/estimates/price?pickup_lat&pickup_lng&dropoff_lat&dropoff_lng[&vehicle_type]` → `{estimates:[{vehicle_type, base_fare, distance_rate, time_rate, distance_fare, time_fare, surge_multiplier, total}]}` — computed by the real fare engine (base + distance + time + surge) from an A\* route
  - `GET /api/v1/estimates/eta?from_lat&from_lng&to_lat&to_lng` → `{eta_seconds, distance_meters}` — route-based travel time before booking
  - `GET /api/v1/geo/eta` (same params) → voyage-computed; the matching driver's arrival ETA is also pushed live on accept: `ride.updated` carries real `eta_seconds` (driver position → pickup, US-6)
- **Notes:** The fare engine (`FareService.CalculateEstimate`: base + distance + time + surge over real A\* routing, `internal/service/fare.go`) is wired into `estimates/price`. `eta_seconds` is no longer hardcoded — `geo/eta` + `estimates/eta` compute route-based ETA, and the accept payload computes driver→pickup ETA (300 s fallback when driver location/routing is unavailable, `service/dispatch.go:173-197`).
  - The price response's `distance_rate`/`time_rate` fields now carry the real per-km/per-min card rates (`handler/platform.go:414-415`, `service/fare.go:164-165`) instead of the leg totals; the earlier v3 rate-field bug is fixed.
  - **Rate card is DB-backed and region-scoped** (`fare_rates`, migration `019_region_fares`): the quoted fare is snapshotted onto the ride at booking (including `fare_region_id`/`fare_rate_id`), only the active version of a region's card prices a trip, and `vehicle_type` is a closed enum (unknown → sedan). Real GPS-time/distance completion fares and earnings/withdraw remain deferred; per-region/time-of-day pricing has landed (`api_plans/STATUS.md` [fare]).
- **Code state:** `handler/platform.go:298` (price, rates `:414-415`), `handler/platform.go:356` (eta); dispatch ETA `service/dispatch.go:173-197`; rates `service/fare.go:112-176`. Covered by `tests/routing_test.go` (TestEstimates, TestGeoETA) and `tests/ride_lifecycle_test.go` (accept `eta_seconds`).
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
- **Code state:** create `handler/ride.go:59-90` + `service/ride.go:33-89`; fare `service/fare.go:112-176` (unified multiplier `143-145`); idempotency middleware `middleware/idempotency.go:11-45`.

## US-6 Wait for a driver **[IMPLEMENTED]**
- **App status:** Rider app 🟢 wired (WS contract realigned to `ride.updated`; no invented event names; current-ride poll drives the fallback + restore) · Driver app — n/a
**As a** rider, **I want** to see the searching state and driver availability, **so that** I know the request is live.

- **Screen:** Searching for driver
- **API:**
  - WebSocket: keep `/ws` open; watch for `ride.updated` → `status:"accepted"` or `status:"no_driver_available"`.
  - `GET /api/v1/rides/current` → `{ride|null}` (poll fallback if WS drops)
- **Notes:** The backend dispatches within expanding radii `{500, 1000, 2000, 5000, 10000} m`, offering to at most **5** drivers, waiting up to **30 s** per driver, and only delivering offers to drivers with a **live `/ws` connection** (`hub.IsConnected`).
  - **Behavior nuance:** at each larger radius the query still returns the same nearest ≤5 drivers (ordered by distance), so the same driver may be re-offered across radii; worst case is 5 radii × 5 sequential attempts, not 25 fresh drivers.
  - If no driver accepts, the ride becomes `no_driver_available` **and the backend now pushes it** as `ride.updated` (`service/dispatch.go:65-74,89-93`) — v2's "never pushed" gap is closed.
  - **WS silence:** push during long searches is still dependent on a live `/ws`; the matching UI must not fake a timeout and relies on `GET /rides/current` for the final outcome.
- **Code state:** `service/dispatch.go` (radii `:42`, `maxLimit=5` `:43`, 30 s `:107`, WS-gated `:82-85`, `no_driver_available` push `:65-74,89-93`). Indirectly covered by `tests/ride_lifecycle_test.go` (decline path); **no direct `no_driver_available` test exists**.
- **Acceptance:** the searching state stays honest during long silent matches (no fake timeout); "no driver" is detected via the `GET /rides/current` poll (LC-2) and the WS push (plan 08).

## US-7 Track the matched driver **[IMPLEMENTED]**
- **App status:** Rider app 🟡 partial (WS now parses the typed `driver`/`driverLocation` into state, but they are never rendered — `ActiveRideScreen` reads invented flat keys `driver_lat`/`driver_lng`/`driver_name`/`car_model`, so real events show "Unknown Driver" with no live marker) · Driver app — n/a
**As a** rider, **I want** to see my driver's info, vehicle, and live location, **so that** I know who is coming and when.

- **Screen:** Driver on the way
- **API:**
  - WebSocket: `ride.updated` → `status:"accepted"` carries `driver {id, first_name, photo_url, rating, vehicle, location}`.
  - WebSocket: `driver.location` events stream the driver's position during the trip.
  - `GET /api/v1/drivers/:id/location` → `{lat, lng, heading, speed, ...}` (polling fallback, **real PostGIS query**) — still declared-but-unused in the app
- **Notes:**
  - Live driver telemetry is only pushed while the driver is streaming `PUT /api/v1/geo/driver/location`.
  - `eta_seconds` in the accept payload is computed from the driver's live position → pickup via the routing engine (`service/dispatch.go:160-208`).
  - The driver `rating` payload is unreliable: `service/dispatch.go:156` does `strconv.ParseFloat(driver.RatingSummary, 64)` but the column stores JSON `{"average":0,"count":0}` — the parse fails and rating comes through as `0.0`.
- **Code state:** accept broadcast `service/dispatch.go:132-205`; location stream `handler/geo.go:42-76` + `repository/geo_repo.go:30-47`; polling fallback `handler/geo.go:186-194`. App: typed parsing `rider_app/lib/features/home/data/ride_status_provider.dart:95-107,121-127`; invented-key render `.../presentation/active_ride_screen.dart:109-113,173-174`.
- **Acceptance:** the driver card + marker render from the typed `accepted` payload; live moves come from `driver.location` with `GET /drivers/:id/location` as fallback; rating `0.0` displays as "New"; the invented `driver_lat`/`driver_name` keys in `active_ride_screen.dart` are replaced by the typed state (LC-4).

## US-8 Ride in progress **[IMPLEMENTED]**
- **App status:** Rider app 🟢 wired (route polyline fetched from `GET /navigation/route` and rendered with a zoom-to-fit; straight-line fallback while loading/error) · Driver app — n/a
**As a** rider, **I want** to follow the trip and see the route, **so that** I can plan my time and feel informed.

- **Screen:** Active trip
- **API:**
  - WebSocket: `ride.updated` → `status:"driver_arrived"`, then `status:"in_progress"`.
  - `GET /api/v1/navigation/route?from_lat=&from_lng=&to_lat=&to_lng=` → `{polyline, total_distance_m, total_duration_s}` — **real A\* road routing** over the OSM road graph (endpoints pinned to the exact pickup/dropoff)
  - `GET /api/v1/rides/:id` → full ride object (authoritative state)
- **Notes:**
  - Route duration is approximated as `distance / 11` (≈ 40 km/h constant), not true travel-time routing (`service/navigation.go:42-43`).
  - `PUT /api/v1/rides/:id/destination` (change destination / add a stop mid-trip) is **[IMPLEMENTED]** — rider-only and owner-only, allowed while the ride is `pending`/`accepted`/`driver_arrived`/`in_progress`; moves `rides.dropoff_*` and the itinerary's destination stop in one transaction. It does not transition status, does not reprice, and does not re-route (re-request `GET /navigation/route`). `POST /api/v1/rides` and `GET /api/v1/rides/:id` accept and return the ordered `stops` itinerary.
  - Before a road network is imported, `/navigation/route` returns 500 `"road network not imported"` and the app renders its straight-line fallback.
- **Code state:** route `handler/platform.go:402` (+ strict coord validation `:520-539`), `repository/navigation_repo.go:56-79,116-143` (A\* graph), `internal/routing/routing.go:101-149`; multi-stop + destination change `handler/ride.go:103` (create w/ `stops`), `:172`/`:229` (`{ride, stops}`), `:285` (`UpdateDestination`), `service/ride.go:165` (`BuildItinerary`), `:408` (`ChangeDestination`), `repository/ride_repo.go:97` (`FindStopsByRideID`), `:165` (`ReplaceDestination`), migration `016_ride_stops`, route `router/router.go:240`. App: `home_provider.dart:122-135`, polyline render + `_fitBounds` `home_screen.dart:31-39,110-137`. Covered by `tests/navigation_test.go`.
- **Acceptance:** the active trip renders the route polyline from `GET /navigation/route` and tracks `driver.location` while in progress (LC-4).

## US-9 Trip complete & fare **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (receipt declared-but-unused) · Driver app — n/a
**As a** rider, **I want** to see the final fare breakdown when the trip ends, **so that** I can review charges.

- **Screen:** Fare / Receipt
- **API:**
  - WebSocket: `ride.updated` → `status:"completed"` includes `fare {base_fare, distance_fare, time_fare, surge_multiplier, total}`.
  - `GET /api/v1/rides/:id/receipt` → `{receipt:{base_fare, distance_fare, time_fare, surge_multiplier, total}}` — durable, DB-backed
- **Notes:**
  - **Completion echoes the booked estimate unchanged:** the final fare is the booking-time snapshot (`service/ride.go:373-396`), not a GPS recompute — the ride row carries no odometer/duration telemetry, so manufacturing a different completion fare would be fabricated. Distance/time fare components are *not* recomputed.
- **Code state:** `service/ride.go:373-396`; receipt `handler/ride.go:330-347`. Covered by `tests/ride_lifecycle_test.go`.
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
  - The read-back endpoints `GET /api/v1/rider/ratings` / `GET /api/v1/driver/ratings` are **[IMPLEMENTED]** — rater-scoped, newest-first, 1-based paginated (`RideHandler.GetRatings`, `handler/ride.go:427`; routes `router/router.go:181,203`).
  - `drivers.rating_summary` is **never recalculated**, so aggregate ratings never reflect new ratings.
- **Code state:** `handler/ride.go:258-293` → `service/ride.go:192-207` → `repository/ride_repo.go:177-183`.
- **Acceptance:** rating posts `POST /rides/:id/rate` with a double-submit guard (LC-3).

## US-11 Cancel a ride **[IMPLEMENTED]**
- **App status:** Rider app 🟢 wired (real `POST /rides/:id/cancel` from `active_ride_screen.dart:75` and `driver_matching_screen.dart:60`; the 1 s mock is gone) · Driver app — n/a
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
- **App status:** Rider app 🟡 partial (GET /rider/me used for auth check; ProfileScreen is hardcoded "Rider"/"rider@example.com"; PUT /rider/me + device registration ⚪ in-app) · Driver app — n/a
**As a** rider, **I want** to view/edit my profile and register my device, **so that** my details and push notifications are correct.

- **Screens:** Profile / Settings
- **API:**
  - `GET /api/v1/rider/me` → `{user, rider}` **[IMPLEMENTED]**
  - `PUT /api/v1/rider/me` — body `{first_name, last_name, photo_url, phone?}` **[IMPLEMENTED]**
  - `PUT /api/v1/rider/me/status` — body `{status}` **[IMPLEMENTED]**
  - `DELETE /api/v1/rider/me` — soft-deletes the account **[IMPLEMENTED]**
  - `POST /api/v1/devices` (alias `POST /api/v1/device-tokens`) — body `{token, platform}` — **[IMPLEMENTED]**: upserts `device_tokens`; `token` is globally unique, so a token that moves to another account is reassigned and stops delivering to the previous owner
  - `DELETE /api/v1/devices/:token` (alias `/api/v1/device-tokens/:token`) on app uninstall — **[IMPLEMENTED]**: deactivates the caller's own token; idempotent
- **Notes:** The profile half is fully real. The API-side push pipeline is landed (`api_plans/STATUS.md` → Landed `[push]`): device persistence, an injectable FCM/APNs/web provider seam whose credential-free default is a log-and-continue no-op, and backgrounded ride notifications. What remains is **app-side**: neither Flutter app calls `POST /devices` yet, so no token is registered in practice.
- **Code state:** profiles `handler/rider.go`; devices `handler/platform.go` (`DeviceRegister`/`DeviceUnregister`), `repository/device_token_repo.go`, migration `018_push_pipeline.up.sql`; push `service/push/{provider,service}.go`.
- **Acceptance:** profile renders `GET /rider/me` and persists edits via `PUT /rider/me` (AC-2); the device endpoints persist and reassign tokens; the apps still need to call them (follow-up).

## US-14 Ride history **[IMPLEMENTED]**
- **App status:** Rider app ❌ stubbed (HistoryScreen shows a fake "No rides yet"; ridesHistory declared-but-unused) · Driver app — n/a
**As a** rider, **I want** a paginated list of past trips, **so that** I can re-book or reference them.

- **Screen:** History
- **API:**
  - `GET /api/v1/rides/history?page=1&per_page=20` → `{rides, total, page, per_page, total_pages}`
- **Code state:** `handler/ride.go:151-189` (paginated DB query). Covered by `tests/ride_lifecycle_test.go`.
- **Acceptance:** history is a paginated list from `GET /rides/history` with infinite scroll (LC-5, plan 04).

## US-15 View the fare receipt **[IMPLEMENTED]**
- **App status:** Rider app ⚪ not implemented (receipt declared-but-unused; plan `rider_app_plans/[tracking]_ride_detail_receipt_rating.md`) · Driver app — n/a
**As a** rider, **I want** to open the fare receipt again after the trip (and from history), **so that** I can review or dispute charges.

- **Screen:** Receipt (re-openable from History)
- **API:**
  - `GET /api/v1/rides/:id/receipt` → `{receipt:{base_fare, distance_fare, time_fare, surge_multiplier, total}}` — durable, DB-backed
- **Notes:** Distinct from US-9 (fare shown at the moment of completion via WS): this is the durable receipt screen, reachable at any time after the trip ends.
- **Acceptance:** the receipt screen renders numbers from `GET /rides/:id/receipt`, not from client-side fakes (LC-3).
- **Code state:** `handler/ride.go:330-347`.

## US-16 No driver available **[IMPLEMENTED]**
- **App status:** Rider app 🟢 wired (5 s `GET /rides/current` poll + `no_driver_available` surfacing landed with plans 02 + 08; the matching screen shows "no drivers found") · Driver app — n/a
**As a** rider, **I want** to be told when no driver accepted my trip, **so that** I can retry or change plans.

- **Screen:** Searching / Matching
- **API:**
  - `GET /api/v1/rides/current` → `{ride|{status:"no_driver_available"}}` — the poll path (5 s cadence, stops at the final status).
  - WebSocket: `ride.updated` → `status:"no_driver_available"` — **now pushed** by the backend at dispatch give-up (`service/dispatch.go:65-74,89-93`); v2's "never pushed" gap is closed.
- **Notes:** [IMPLEMENTED] since v3 — both the push and the poll are real. Dispatching can legitimately take up to 5 radii × 30 s (US-6), so the client must keep poll + WS alive during the wait.
- **Acceptance:** when dispatch gives up, the matching UI shows "no drivers found" + a retry, driven by the `GET /rides/current` poll (LC-2) and the `no_driver_available` push.

## US-17 Re-book from history **[IMPLEMENTED]**
- **App status:** Rider app 🟡 history list landed (`[history]` — STATUS.md); one-tap re-book (LC-5) not implemented · Driver app — n/a
**As a** rider, **I want** to repeat a past trip with one tap, **so that** I don't re-enter addresses.

- **Screen:** History
- **API:**
  - `GET /api/v1/rides/history?page=1&per_page=20` — each ride carries its `pickup_address`/`dropoff_address`.
- **Notes:** All data needed already comes from the history endpoint.
- **Acceptance:** tapping a past ride prefills the booking form (pickup/dropoff) (LC-5).

---

# Part B — Driver app (the driver)

## US-D1 Create a driver account **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟡 partial (bootstrap onboarding promotes via `POST /driver/register` and rotates the JWT to the `driver` role; the first/last-name fields are never transmitted — "Identity field persist is a follow-up", `onboarding_screen.dart:40-41`)
**As a** driver, **I want** to create an account and register as a driver, **so that** I can start receiving ride requests.

- **Screens:** Onboarding → Driver registration
- **API:**
  - `POST /api/v1/auth/register` — body `{email, phone, password}` → creates the account in the `rider` role
  - `POST /api/v1/driver/register` (auth) → `201 {driver:{status:"offline", onboarding_status:"documents_submitted"}}` promotes the user to `driver`
- **Notes:** After promotion the account holds the `driver` role, so the driver app uses the driver endpoints. Document *upload/verification* endpoints are [STUB] (US-D3 / Part C).
- **Code state:** `handler/driver.go:34-49`; driver-app `auth_provider.dart:169-188` (`registerAsDriver`). Covered by `tests/dispatch_test.go`.
- **Acceptance:** onboarding performs `POST /driver/register` and the account then holds the `driver` role (M2); the collected names persist via `PUT /driver/me` — **landed**, `[profile]` in `driver_app_plans/STATUS.md`.

## US-D2 Log in **[IMPLEMENTED]**
- **App status:** Rider app — n/a (same auth stack, see US-2) · Driver app 🟢 wired (bootstrap: login/register/logout + refresh wired incl. 401 single-flight auto-refresh; forgot/reset-password are real HTTP)
**As a** driver, **I want** to log in and get tokens, **so that** I can go online and connect to live offers.

- **Screen:** Login
- **API:**
  - `POST /api/v1/auth/login` → `200 {access_token, refresh_token, user}`
  - `POST /api/v1/auth/refresh` on token expiry; `POST /api/v1/auth/logout` on sign-out
- **Notes:** Same real auth stack as US-2.
- **Acceptance:** login routes to Home; a mid-session 401 auto-refreshes once (M1).

## US-D3 Set up profile & vehicle **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app 🟡 partial (`GET /driver/me` rendered in Profile/Home; `PUT /driver/me` edit wired via `ProfileNotifier.updateProfile` — sends only provided fields, `profile_notifier.dart:56-100`; vehicle & documents screens exist but are feature-gated off, `vehicle_screen.dart:25-28` shows "Coming soon")
**As a** driver, **I want** to add my name/photo and vehicle details, **so that** riders see who is coming for them.

- **Screen:** Profile / Vehicle
- **API:**
  - `GET /api/v1/driver/me` → `{driver:{..., vehicle}}` and `PUT /api/v1/driver/me` — body `{first_name, last_name, photo_url}` — **[IMPLEMENTED]**
  - `GET /api/v1/driver/me/vehicle` / `PUT /api/v1/driver/me/vehicle` — **[STUB]** (returns the generic stub payload; no CRUD, no persistence)
- **Notes:**
  - The *read* path used in dispatch is real: `FindVehicleByDriverID` (`repository/ride_repo.go:168-175`) feeds `driver.vehicle` into the accepted `ride.updated` payload — but there is **no real source of vehicle data** to write, and in tests a synthetic "Toyota Camry / ABC-1234" is fabricated (`tests/testutil/mock_repos.go`). This must be real before launch.
- **Code state:** profile `handler/driver.go:59-93`; vehicle stub `router.go:132-133` → `handler/platform.go:497`.
- **Acceptance:** profile renders `GET /driver/me`; vehicle/documents screens feature-gated until the backend is real (M10).

## US-D4 Go online **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟢 wired (online/offline switch posts `PUT /driver/me/status` via `AvailabilityNotifier.toggle` — double-tap guarded, error reverts state; `LocationService` pushes `PUT /geo/driver/location` throttled to ≥5 s only while online and flushes buffered points via `PUT /geo/driver/location/batch` on recovery; WS lifecycle rides the auth session — plan `driver_app_plans/STATUS.md` `[online]` landed)
**As a** driver, **I want** to set myself online and start broadcasting my location, **so that** the dispatcher can offer me rides.

- **Screen:** Home / Availability
- **API:**
  - `PUT /api/v1/driver/me/status` — body `{status:"online"}` (use `"offline"` to stop)
  - `PUT /api/v1/geo/driver/location` — body `{lat, lng, heading, speed}` → `204` (stream periodically; batch via `PUT /api/v1/geo/driver/location/batch`)
  - `GET /ws` — open the authenticated WebSocket to receive offers
- **Notes:** Dispatch only offers rides to drivers whose `/ws` connection is live (`hub.IsConnected`), so online + WS + location must all be active.
- **Code state:** `handler/driver.go:105-117`, `handler/geo.go:42-105`, `hub.go:119-124`. Driver-app WS connect wiring: `websocket_service.dart:30-98`.
- **Acceptance:** the online toggle drives status + location stream + WS lifecycle (done, plan `driver_app_plans/STATUS.md` `[online]`).

## US-D5 Receive a ride request **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟢 wired (`RideStateNotifier` listens for `ride.offer` — single-offer policy, 30 s timeout that auto-expires; `HomeScreen` opens `OfferSheet` on the offered ride if online; the sheet fetches `GET /driver/rides/:id` for details with a 5 s timeout and error text — plan `driver_app_plans/STATUS.md` `[offer]` landed)
**As a** driver, **I want** to see an incoming trip offer with the key details, **so that** I can decide whether to take it.

- **Screen:** Ride offer
- **API:**
  - WebSocket: `ride.offer` → `{ride_id}` (the offer payload **only carries the id** today)
  - `GET /api/v1/driver/rides/:id` → full ride `{pickup_lat/lng/address, dropoff..., vehicle_type, status:"pending", fares}` — real, DB-backed (no ownership scoping)
- **Notes:** Offer context (distance to pickup, fare, TTL) therefore requires a follow-up `GET /driver/rides/:id`. A richer offer payload is a Part C improvement.
- **Code state:** offer push `service/dispatch.go:99-102`; ride detail `handler/ride.go:130-138`.
- **Acceptance:** the offer dialog fetches `GET /driver/rides/:id` for details (done, plan `driver_app_plans/STATUS.md` `[offer]`).

## US-D6 Accept the ride **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app 🟢 wired (accept sends WS `ride.accept` first when `isConnected`, else the HTTP fallback `POST /driver/rides/:id/accept` via `claimOfferViaHttp()` — a 409 surfaces as "Trip no longer available" (`OfferExpiredException`); decline sends WS `ride.decline`; accept/decline buttons disable at the expiry deadline (`offerExpiresAt`) — plan `driver_app_plans/STATUS.md` `[offer]` landed)
**As a** driver, **I want** to accept a matching offer, **so that** the rider is notified and the trip moves to `accepted`.

- **Screen:** Ride offer
- **API:**
  - Primary (live): WebSocket message `ride.accept` → `{ride_id}`; wired to `DispatchService.HandleAccept` — but **requires an active offer**, and does **not verify the sender is the offered driver** (offer channels are keyed by ride ID only) — any authed user knowing a ride ID can accept.
  - Fallback/HTTP: `POST /api/v1/driver/rides/:id/accept` → `200 {message:"ride accepted"}` or `409` if another driver took it — **does not require an active offer**; assignment is guarded by `WHERE status='pending'`.
  - WebSocket: both driver and rider receive `ride.updated` → `status:"accepted"` with driver info + real `eta_seconds` (driver position → pickup).
- **Notes:** Declining via WebSocket `ride.decline` → `{ride_id}` works (`HandleDecline`). The HTTP `POST /api/v1/driver/rides/:id/decline` is a [STUB]. Offers expire after 30 s (dispatch timeout).
- **Code state:** hub routing `websocket/hub.go:95-110`; HTTP accept `service/dispatch.go:132-205` (conflict `handler/ride.go:305-319`); decline HTTP stub `router.go:146` → `handler/platform.go:497`.
- **Acceptance:** accept via WS `ride.accept` with the HTTP fallback; decline is WS-only (done, plan `driver_app_plans/STATUS.md` `[offer]`).

## US-D7 Navigate to the pickup **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟢 implemented (`TripScreen` requests `GET /navigation/route` on mount and refetches when the driver's GPS fix moves >200 m (destination-anchored cache, real haversine), drawing the road polyline with pickup/dropoff/driver markers on a `flutter_map`; a failure or an `is_estimate` straight line renders as a dashed overlay. No turn-by-turn guidance — plan `driver_app_plans/STATUS.md` `[trip]` landed)
**As a** driver, **I want** turn-by-turn guidance to the pickup point, **so that** I arrive efficiently.

- **Screen:** Navigation
- **API:**
  - `GET /api/v1/navigation/route?from_lat=&from_lng=&to_lat=&to_lng=` → `{polyline, total_distance_m, total_duration_s}` (+ `is_estimate: true` outside road coverage, `api_plans/STATUS.md` `[routing]`)
- **Notes:** Same real A\* road-routing service as US-8; duration is the `distance / 11` approximation. The route origin is always the **driver's own** live fix — the server only pushes `driver.location` to the rider, so the driver app never has a rider position to route from.
- **Code state:** `handler/platform.go:402`, `internal/routing/routing.go:101-149`.
- **Acceptance:** the nav screen renders the polyline from `GET /navigation/route` (done, plan `driver_app_plans/STATUS.md` `[trip]`; turn-by-turn guidance remains open).

## US-D8 Arrived at pickup **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟡 partial (the trip screen's "Arrived at pickup" button sends `PUT /driver/rides/:id/status` with `driver_arrived` via `TripNotifier.advance`, and `TripStage.arrived` is now a distinct stage — merging it into `enrouteToPickup` made the first press send `in_progress` from `accepted`, which the server rejects with 400. The app skips `POST /notify-arrival` because the status transition already notifies)
**As a** driver, **I want** to mark that I arrived and notify the rider, **so that** the rider comes out.

- **Screen:** Arrival
- **API:**
  - `PUT /api/v1/driver/rides/:id/status` — body `{status:"driver_arrived"}` — **[IMPLEMENTED]**, state machine enforced, echoed as `ride.updated`
  - `POST /api/v1/driver/rides/:id/notify-arrival` → `200 {message}` — **[IMPLEMENTED]**: sends a live `ride.updated` (`driver_arrived`) to a connected rider, or a backgrounded push when the rider is offline; ancillary (no status write); 404 for another driver's / an unknown ride
- **Notes:** The endpoint no longer depends on a missing pipeline — the API-side push delivery pipeline landed (`api_plans/STATUS.md` → Landed `[push]`). The credential-free default provider logs and continues.
- **Code state:** status advance `handler/ride.go` → `service/ride.go`; notify-arrival `handler/platform.go` (`ArrivalNotification`), push `service/push/`.
- **Acceptance:** arrival sets `driver_arrived` via `PUT /driver/rides/:id/status` (done); `notify-arrival` is a real send when called, and a no-op failure path that never changes the ride.

## US-D9 Start and complete the trip **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟢 implemented (`RideStateNotifier` (plan 01) merges the WS `ride.updated` patch — the wire shape is `ride_id` + **nested** `pickup`/`dropoff`/`fare`, so parsing it as a flat `Ride` used to blank the id and coordinates — and `TripNotifier` derives one stage per server status (`pre → enrouteToPickup → arrived → driving → post`); `TripScreen`'s primary button advances `driver_arrived → in_progress → completed` via `PUT /driver/rides/:id/status`, the cancel button is a confirm dialog wired to `POST /driver/rides/:id/cancel`, the terminal screen shows the fare card and clears the ride, and a cold start restores the ride from `GET /driver/rides/current` because the WS has no replay — plan `driver_app_plans/STATUS.md` `[trip]` landed)
**As a** driver, **I want** to start the trip when the rider is onboard and complete it at the destination, **so that** the fare is finalized.

- **Screen:** Active trip
- **API:**
  - `PUT /api/v1/driver/rides/:id/status` — body `{status:"in_progress"}`, then `{status:"completed"}`
  - `POST /api/v1/driver/rides/:id/cancel` — driver-initiated, allowed only before `in_progress` (binds no body; `cancelled_by` comes from the caller's role)
  - `GET /api/v1/driver/rides/current` → `{ride}` / `{ride: null}` — launch restore
  - WebSocket: both sides get `ride.updated` → `in_progress`, then `completed` (with the final `fare`).
- **Notes:** Transitions are capped by the assigned driver *role group only* — the handler checks the `driver` role but **not ride ownership** (`handler/ride.go:225-242` reads only the role), so any driver could advance any ride's status. Transitions outside the state machine are rejected with `400`. Completion echoes the booked estimate unchanged (see US-9).
- **Code state:** `service/ride.go:338-410`; covered by `tests/ride_lifecycle_test.go`, `tests/ws_push_test.go`.
- **Acceptance:** the single-button journey drives the state machine to `completed`, with both cancel paths landing on a clean screen (done, plan `driver_app_plans/STATUS.md` `[trip]`).

## US-D10 Rate the rider **[IMPLEMENTED]**
- **App status:** Rider app — n/a · Driver app 🟢 wired (`RateSheet` on the post-trip receipt + a per-trip action in the history list; `POST /driver/rides/:id/rate`. Done, plan `driver_app_plans/STATUS.md` `[history]`)
**As a** driver, **I want** to rate the rider after the trip, **so that** rider quality is tracked.

- **Screen:** Rating
- **API:**
  - `POST /api/v1/driver/rides/:id/rate` — body `{score: 1..5, comment}` → `200 {message}`
- **Notes:** Same rating persistence + gaps as US-10 (no `completed`/party check; read-back stub; summary never updated). ⚠️ The body field is **`score`**, not `rating` — `rateRideRequest.Score` is `json:"score" binding:"required"`, so a `rating` key binds to zero and the call 400s. `driver_app_plans/STATUS.md` `[history]` originally specified `rating` and was corrected against the handler.
- **Code state:** `handler/ride.go:258-293`; `service/ride.go:192-206` only range-checks the score, so the app enforces the "only a completed ride" rule itself.
- **Acceptance:** rating posts `POST /driver/rides/:id/rate` (M8, plan `driver_app_plans/STATUS.md` `[history]` — done).
- **App notes:** 1–5 stars + an optional 280-char comment; submit stays disabled while in flight (no double submit) and a failure keeps the sheet open with an inline error, because the driver has no server-side way to notice a rating was dropped. "Already rated" is seeded from the real paginated `GET /driver/ratings` read (`handler/ride.go:427`); the history rows carry no rated-by-driver flag, so the set comes from that endpoint rather than the ride rows.

## US-D11 View history & earnings **[PARTIAL]**
- **App status:** Rider app — n/a · Driver app 🟢 wired for history + derived earnings (`RidesHistoryScreen` with the earnings header, infinite scroll and a rating action per completed trip; `GET /driver/rides/history`). The **earnings and withdraw endpoints remain `[STUB]`** and are deliberately not called — the app sums fares client-side instead. Done, plan `driver_app_plans/STATUS.md` `[history]`)
**As a** driver, **I want** to see my ride history and earnings, **so that** I can track my income.

- **Screen:** Earnings / History
- **API:**
  - `GET /api/v1/driver/rides/history?page=1&per_page=20` → `{rides, total, page, per_page, total_pages}` — **[IMPLEMENTED]** (paginated)
  - `GET /api/v1/driver/rides/current` → `{ride|null}` — **[IMPLEMENTED]** (check active trip)
  - `GET /api/v1/driver/me/earnings` — **[STUB]**
  - `GET /api/v1/driver/rides/queue` — **[STUB]** (always `{queue:[]}`)
  - `POST /api/v1/driver/earnings/withdraw` — **[STUB]**
- **Notes:** `driver_app_plans/STATUS.md` `[history]` originally specified `limit`/`offset` pagination and was corrected: the handler takes 1-based `page` + `per_page` (clamped to 1..50, and out-of-range values are **silently rewritten**, so a bad one returns a valid-looking page rather than an error). Rows are `SELECT *` ordered `created_at DESC`, so each later page is strictly older and the fare columns are present. ⚠️ Because history is paginated, a **client-side** earnings sum only covers the pages loaded so far — the card says so rather than implying an all-time balance, and there is no withdraw affordance at all.
- **Code state:** history/current `handler/ride.go:100-189`; stubs `handler/platform.go:497`, `router.go:211-213`.
- **Acceptance:** history + client-side earnings derived from `GET /driver/rides/history`; withdraw hidden (M9, plan `driver_app_plans/STATUS.md` `[history]` — done).

---

# Part C — Missing / stubbed work to build next

Everything here was re-verified against the working tree (HEAD `8a3a13f`, 2026-09-11). API tier tags: **[STUB]** = endpoint exists but returns placeholders; **[PARTIAL]** = real with a stub/hardcoded sub-path; **[MISSING]** = no endpoint/route at all. App tier marks (Rider app / Driver app) use the legend at the top of this document. Cells repeat the Appendix matrix values so Part C is self-contained.
- **How fares are quoted:** rates are region-scoped, versioned rows in `fare_rates` (migration `019_region_fares`; engine `service/fare.go`), selected by the resolved region and snapshotted onto the ride at booking (see US-4). Actual GPS-based completion fares remain deferred.

### Core booking trip (US-3 → US-12)

| Endpoint | API | Rider app | Driver app | Needed for |
|---|---|---|---|---|
| `GET /api/v1/places/geocode?lat=&lng=` | [IMPLEMENTED] | ⚪ (app uses manual address entry) | — n/a | Reverse-geocode a map pin to an address on the Home screen (US-3); real since v3 — nearest place within radius, `null` when none (`handler/platform.go:235`) |
| `GET /api/v1/places/details?id=` | [STUB] | ⚪ | — n/a | Address/place details for a search result (US-3) |
| `GET /api/v1/estimates/price` + `GET /api/v1/estimates/eta` + `GET /api/v1/geo/eta` | price [IMPLEMENTED] (rate fields now real); eta/geo-eta [IMPLEMENTED] | 🟢 price wired (real totals); eta endpoints ⚪ unused | ⚪ | Render the live price/ETA responses anywhere they are surfaced (US-4, US-6); accept-payload ETA falls back to `300` only when driver location/routing is unavailable |
| `GET /api/v1/driver/rides/:id/rider` | [STUB] | — n/a | ⚪ (planned: placeholder gated, M4) | Real rider name/rating/photo for the driver after accepting (US-D6); today returns hardcoded `{"name":"Rider","rating":5.0}` |
| `PUT /api/v1/rides/:id/destination` | [IMPLEMENTED] | ⚪ | ⚪ | Change destination / add a stop mid-trip (US-8); persists the new destination, status and fare unchanged |
| `POST /api/v1/sos` | [STUB] | ⚪ declared-but-unused | ⚪ (`sos` declared-but-unused) | Persist to the existing `sos_alerts` table and dispatch to emergency contacts/support (US-12) |
| `POST /api/v1/feedback` | [IMPLEMENTED] | ⚪ | ⚪ (driver safety screen sends `{type, message}`) | Persisted to the `feedback` table, `type` included (migration 018); admin triage tooling still missing |

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
| `GET/PUT /api/v1/driver/me/vehicle` | [STUB] | — n/a | ⚪ feature-gated off (screen ships behind `vehicleFeatureEnabled=false`; reads the stub when the flag is on) | Vehicle CRUD; riders see the vehicle in `ride.updated`, and today the payload relies on a fabricated test vehicle. Must be real before launch |
| `GET/POST /api/v1/driver/me/documents` | [STUB] | — n/a | ⚪ declared-but-unused (planned: feature-gated, M10) | Document upload + verification/approval workflow for onboarding |
| `GET /api/v1/driver/me/earnings` | [STUB] | — n/a | ⚪ declared-but-unused (planned: derived client-side, M9) | Earnings dashboard |
| `POST /api/v1/driver/earnings/withdraw` | [STUB] | — n/a | ⚪ declared-but-unused (planned: entry hidden, M9) | Payout requests |
| `GET /api/v1/driver/ratings` and `GET /api/v1/rider/ratings` | [IMPLEMENTED] | ⚪ | ⚪ | Rating reads are real: rater-scoped, newest-first, paginated (`handler/ride.go:427`); `rating_summary` is still never recalculated |

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
| Push delivery pipeline | [IMPLEMENTED] server-side (device register/unregister real) | ⚪ app does not call `POST /devices` yet | ⚪ (offers only while `/ws` open) | API delivers `notify-arrival` and ride status updates when the app is backgrounded; the apps' token registration is the remaining follow-up |

### Cross-cutting gaps

| Gap | API | Rider app | Driver app |
|---|---|---|---|
| Ride offers only delivered while the driver keeps `/ws` open | [IMPLEMENTED] (dispatch gate, `hub.IsConnected`) | — n/a | ⚪  (plan pins WS + location lifecycle to the online toggle, M3) |
| No admin endpoints (SOS triage, document verify, feedback review) | [MISSING] | — n/a | — n/a (admin/support tooling, not an app surface) |
| Idempotency-Key incomplete (empty-body replay, no concurrent guard, untested) | [PARTIAL] | 🟡 retries reuse the key but a replay returns an empty body the app must tolerate | — n/a |
| Completion fare from actual GPS telemetry (today echoes the booked estimate) | [PARTIAL] | ⚪ (receipt unused today) | ⚪ (fare shown = booked estimate) |
| Rating aggregate never recalculated (`rating_summary` stale, WS parses to `0.0`) | [PARTIAL] | ⚪ | ⚪ (driver rating shown from `rating_summary`) |

### Review-notes triage (2026-09-26)

Folded `rider_app/review_notes0926.md` into the plan tree. Every item below is net-new work with
an owning plan; two notes turned out to be already implemented and are recorded as such so they
are not re-filed.

| Item | Owner plan | Note |
| --- | --- | --- |
| Multi-stop / change destination (add stops) | **landed** — `api_plans/STATUS.md` → Landed `[multi]` | API half landed: `ride_stops` (migration 016), ordered `stops` on create/read, and a real `PUT /rides/:id/destination` (`handler/ride.go:285`). App half still pending |
| "Cancel session & new login" / switch account | **both sides landed** — `[session]` in `rider_app_plans/STATUS.md` and `driver_app_plans/STATUS.md` | Guarded `needsAccountSwitch`/`switchAccount` cancels the stored refresh token before re-login; `login()` no longer silently overwrites (`shared/lib/src/auth/app_auth_controller.dart:135-185`) |
| Rider gets `no_driver_available` while a driver is online | **landed** — `[dispatch]` in `api_plans/STATUS.md` + `driver_app_plans/STATUS.md` | 30 s position window + never-called `MarkStaleDriversOffline` + WS `isConnected` offer skip + no driver keep-alive `ping()` |
| Autocomplete sends too many requests | **landed** — `[search]` (STATUS.md) | 350 ms debounce + single 30 km-radius request (`home_provider.dart:51-54`, `location_search_screen.dart:37-43`); was no debounce (`location_search_screen.dart:50`) + up-to-4-request radius upscaling (`home_provider.dart:51,58`) |
| Rider live route + ETA on-trip | `rider_app_plans/01_[ontrip]_live_route_and_eta.md` | `active_ride_screen.dart:135` draws a straight line, no road route, no ETA; typed `etaSeconds`/`driverLocation` already in state |
| Fare "stubbed" on both apps | **landed** — `[fare]` (STATUS.md): 1.1× replaced with the real booked estimate; `distance_rate`/`time_rate` now carry real per-km/per-min rates |
| Rider notified on driver arrival (backgrounded) | **landed** — `api_plans/STATUS.md` → Landed `[push]` | live `ride.updated` over an open WS; backgrounded push when offline — `notify-arrival` and ride status transitions push via `service/push/`; device register/unregister persist |

**Already-implemented (do not re-open):** the driver's route-to-pickup → route-to-destination is
landed (`driver_app/.../trip_screen.dart` `_targetFor`, real polyline), so review notes "on accept,
render route to pickup" / "on start, render route to destination" are stale. The driver marker on the
rider map is the tracked known-bug #1 + open `[tracking]` LC-4, not a new plan. `[auth]_forgot_password`,
`[history]`, `[geo]`, `[safety]` and `[session]` have since landed (see STATUS.md).

---

# Appendix

## Story × app status (all user stories)

Matrix of every story (Part A + Part B) against the three tiers. API — ✅ `[IMPLEMENTED]` · 🟡 `[PARTIAL]` · ❌ `[STUB]`. App — 🟢 wired · 🟡 partial · ❌ stubbed · ⚪ not implemented · — n/a (see the Status legend). This is the story-level rollup; the per-endpoint expansion is the endpoint matrix below. Each story body in Parts A/B carries the *why*.

| Story | API | Rider app | Driver app |
|---|---|---|---|
| US-1 Sign up | ✅ | 🟡 register wired; forgot-password fake; verify ⚪ | — |
| US-2 Log in | ✅ | 🟢 login/logout/refresh + 401 auto-refresh | — |
| US-3 Set pickup & destination | 🟡 | 🟡 autocomplete wired; reverse-geocode unused | — |
| US-4 See price & ETA | 🟡 | 🟡 price wired; eta unused | — |
| US-5 Request the trip | ✅ | 🟢 create + idempotency-key reuse | — |
| US-6 Wait for a driver | ✅ | 🟢 WS `ride.updated` + current poll | — |
| US-7 Track the matched driver | ✅ | 🟡 typed state parsed, never rendered | — |
| US-8 Ride in progress | ✅ | 🟢 route polyline + zoom-to-fit | — |
| US-9 Trip complete & fare | ✅ | ⚪ receipt unused | — |
| US-10 Rate the driver | ✅ | ⚪ rate unused | — |
| US-11 Cancel a ride | ✅ | 🟢 real `POST /rides/:id/cancel` | — |
| US-12 Send an SOS | ❌ | ⚪ sos unused | — |
| US-13 Profile & devices | 🟡 | 🟡 auth-check only; screen hardcoded | — |
| US-14 Ride history | ✅ | ❌ fake "No rides yet" screen | — |
| US-15 View the fare receipt | ✅ | ⚪ receipt unused | — |
| US-16 No driver available | ✅ | 🟢 current poll + surfacing | — |
| US-17 Re-book from history | ✅ | ⚪ history unused | — |
| US-D1 Create a driver account | ✅ | — | 🟡 promotes via onboarding; names not sent |
| US-D2 Log in | ✅ | — | 🟢 login/logout/refresh + forgot/reset |
| US-D3 Set up profile & vehicle | 🟡 | — | 🟡 `GET /driver/me` rendered + `PUT /driver/me` edit; vehicle feature-gated |
| US-D4 Go online | ✅ | — | 🟢 online toggle + throttled location stream wired |
| US-D5 Receive a ride request | ✅ | — | 🟢 WS offer → sheet + ride detail |
| US-D6 Accept the ride | 🟡 | — | 🟢 accept (WS + HTTP fallback) / WS decline |
| US-D7 Navigate to the pickup | ✅ | — | 🟢 road polyline + 200 m refetch + dashed fallback; no turn-by-turn |
| US-D8 Arrived at pickup | ✅ | — | 🟡 arrival button wired on its own stage; `notify-arrival` real server-side (app skips it; status transition already notifies) |
| US-D9 Start and complete the trip | ✅ | — | 🟢 full single-button journey, cancel, launch restore, 46 new tests |
| US-D10 Rate the rider | ✅ | — | 🟢 1–5 stars + optional comment from the trip receipt or the history list; session-local "already rated" guard |
| US-D11 View history & earnings | 🟡 | — | 🟢 paged history + client-side earnings by month; withdraw hidden (the endpoint is a stub) |

## Endpoint × app status (full per-endpoint matrix)

Legend — API tier: ✅ `[IMPLEMENTED]` · 🟡 `[PARTIAL]` · ❌ `[STUB]`. App tier: 🟢 wired · 🟠 wired–stub · 🟡 partial · ❌ stubbed · ⚪ not implemented · — n/a (see the Status legend).

| Method | Path | API | Rider app | Driver app | Handler | Code ref |
|---|---|---|---|---|---|---|
| GET | `/health` | ✅ | ⚪ | ⚪ | Health.Liveness | `handler/health.go:25` |
| GET | `/health/ready` | ✅ | ⚪ | ⚪ | Health.Readiness (DB ping) | `handler/health.go:37` |
| GET | `/api/v1/version` | ✅ | ⚪ | ⚪ | Platform.Version (`0.1.0` / "development") | `handler/platform.go:484` |
| POST | `/api/v1/auth/register` | ✅ | 🟢 | 🟢 | Auth.Register | `handler/auth.go:62` |
| POST | `/api/v1/auth/login` | ✅ | 🟢 | 🟢 | Auth.Login | `handler/auth.go:105` |
| POST | `/api/v1/auth/refresh` | ✅ | 🟢 401 single-flight auto-refresh | 🟢 401 single-flight auto-refresh | Auth.Refresh (rotation + reuse rejection) | `handler/auth.go:144` |
| POST | `/api/v1/auth/logout` | ✅ | 🟢 | 🟢 | Auth.Logout | `handler/auth.go:179` |
| POST | `/api/v1/auth/forgot-password` | ✅ | ❌ fake screen, no call | 🟢 | Auth.ForgotPassword (reset token; no email sent in dev) | `handler/auth.go:209` |
| POST | `/api/v1/auth/reset-password` | ✅ | ⚪ | 🟢 | Auth.ResetPassword | `handler/auth.go:244` |
| POST | `/api/v1/auth/verify-email` | 🟡 | ⚪ | ⚪ | sets verified, ignores code | `handler/auth.go:274` |
| POST | `/api/v1/auth/verify-phone` | 🟡 | ⚪ | ⚪ | sets verified, ignores code | `handler/auth.go:306` |
| POST | `/api/v1/auth/social` | ❌ | ⚪ | ⚪ | Auth.SocialLogin | `handler/auth.go:337` |
| GET | `/api/v1/rider/me` | ✅ | 🟢 cold-start auth check (profile never rendered) | — | Rider.GetProfile | `handler/rider.go:41` |
| PUT | `/api/v1/rider/me` | ✅ | ⚪ never declared | — | Rider.UpdateProfile | `handler/rider.go:65` |
| PUT | `/api/v1/rider/me/status` | ✅ | ⚪ never declared | — | Rider.UpdateStatus | `handler/rider.go:98` |
| DELETE | `/api/v1/rider/me` | ✅ | ⚪ | — | Rider.DeleteAccount (soft) | `handler/rider.go:120` |
| GET | `/api/v1/rider/me/preferences` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| PUT | `/api/v1/rider/me/preferences` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| GET | `/api/v1/rider/ratings` | ✅ | ⚪ | — | Ride.GetRatings (rater-scoped, paginated) | `handler/ride.go:427` |
| GET | `/api/v1/rider/favorites` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| POST | `/api/v1/rider/favorites` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| DELETE | `/api/v1/rider/favorites/:id` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| GET | `/api/v1/rider/payment-methods` | ❌ | ⚪ declared-but-unused | — | StubPayment | `handler/platform.go:497` |
| POST | `/api/v1/rider/payment-methods` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| DELETE | `/api/v1/rider/payment-methods/:id` | ❌ | ⚪ | — | StubPayment | `handler/platform.go:497` |
| POST | `/api/v1/driver/register` | ✅ | — | 🟢 (promotes; onboarding names not sent) | Driver.Register | `handler/driver.go:34` |
| GET | `/api/v1/driver/me` | ✅ | — | 🟢 rendered in profile/home | Driver.GetProfile | `handler/driver.go:59` |
| PUT | `/api/v1/driver/me` | ✅ | — | 🟢 edit wired (ProfileNotifier) | Driver.UpdateProfile | `handler/driver.go:79` |
| PUT | `/api/v1/driver/me/status` | ✅ | — | 🟢 online toggle (plan 02) | Driver.UpdateStatus | `handler/driver.go:105` |
| GET | `/api/v1/driver/me/documents` | ❌ | — | ⚪ declared-but-unused | StubPayment | `handler/platform.go:497` |
| POST | `/api/v1/driver/me/documents` | ❌ | — | ⚪ declared-but-unused | StubPayment | `handler/platform.go:497` |
| GET | `/api/v1/driver/me/vehicle` | ❌ | — | ⚪ feature-gated off (`vehicleFeatureEnabled=false`) | StubPayment | `handler/platform.go:497` |
| PUT | `/api/v1/driver/me/vehicle` | ❌ | — | ⚪ declared-but-unused | StubPayment | `handler/platform.go:497` |
| GET | `/api/v1/driver/me/earnings` | ❌ | — | ⚪ declared-but-unused | StubPayment | `handler/platform.go:497` |
| GET | `/api/v1/driver/ratings` | ✅ | — | ⚪ | Ride.GetRatings (rater-scoped, paginated) | `handler/ride.go:427` |
| GET | `/api/v1/driver/rides/current` | ✅ | — | ⚪ declared-but-unused | Ride.GetCurrentRide | `handler/ride.go:100` |
| GET | `/api/v1/driver/rides/history` | ✅ | — | 🟢 paged `page`/`per_page` list + client-side earnings by month | Ride.GetRideHistory | `handler/ride.go:151` |
| GET | `/api/v1/driver/rides/queue` | ❌ | — | ⚪ declared-but-unused | Platform.DriverRideQueue | `handler/platform.go:447` |
| GET | `/api/v1/driver/rides/:id` | ✅ | — | 🟢 offer details (OfferSheet) | Ride.GetRideByID | `handler/ride.go:130` |
| GET | `/api/v1/driver/rides/:id/rider` | ❌ | — | ⚪ declared-but-unused | Platform.DriverRiderInfo (hardcoded) | `handler/platform.go:460` |
| POST | `/api/v1/driver/rides/:id/accept` | ✅ | — | 🟢 HTTP fallback accept (plan 03) | Ride.AcceptRide (409 conflict) | `handler/ride.go:305` |
| POST | `/api/v1/driver/rides/:id/decline` | ❌ | — | ⚪ declared-but-unused (WS-only today) | StubPayment (WS decline works) | `handler/platform.go:497` |
| PUT | `/api/v1/driver/rides/:id/status` | ✅ | — | 🟢 trip journey (plan 04) | Ride.AdvanceStatus | `handler/ride.go:225` |
| POST | `/api/v1/driver/rides/:id/cancel` | ✅ | — | ⚪ `TripNotifier.cancelTrip` exists; Cancel button is a no-op stub | Ride.CancelRide | `handler/ride.go:200` |
| POST | `/api/v1/driver/rides/:id/rate` | ✅ | — | 🟢 `RateSheet` from the trip receipt / history list (`{score, comment}`) | Ride.RateRide | `handler/ride.go:258` |
| POST | `/api/v1/driver/rides/:id/notify-arrival` | ✅ | — | ⚪ app skips it (status transition already notifies) | Platform.ArrivalNotification (WS or backgrounded push; 404 for another driver's ride) | `handler/platform.go` |
| PUT | `/api/v1/geo/driver/location` | ✅ | — | 🟢 throttled push while online (plan 02) | Geo.UpdateDriverLocation | `handler/geo.go:42` |
| PUT | `/api/v1/geo/driver/location/batch` | ✅ | — | 🟢 buffered flush (plan 02) | Geo.UpdateDriverLocationBatch | `handler/geo.go:88` |
| PUT | `/api/v1/geo/rider/location` | ✅ | ⚪ never declared | — | Geo.UpdateRiderLocation | `handler/geo.go:117` |
| GET | `/api/v1/geo/nearby-drivers` | ✅ | ⚪ provider fetches, never rendered → dead code | ⚪ | Geo.GetNearbyDrivers | `handler/geo.go:143` |
| GET | `/api/v1/geo/eta` | ✅ | ⚪ declared-but-unused | ⚪ | Platform.EstimatesETA (A\*) | `handler/platform.go:356` |
| GET | `/api/v1/geo/isochrone` | ❌ | ⚪ | ⚪ | StubPayment | `handler/platform.go:497` |
| POST | `/api/v1/rides` | ✅ | 🟢 | — | Ride.CreateRide (rider only, idempotency) | `handler/ride.go:59` |
| GET | `/api/v1/rides/current` | ✅ | 🟢 5 s poll + restore | ⚪ | Ride.GetCurrentRide | `handler/ride.go:100` |
| GET | `/api/v1/rides/history` | ✅ | ❌ fake "No rides yet" screen | ⚪ | Ride.GetRideHistory | `handler/ride.go:151` |
| GET | `/api/v1/rides/:id` | ✅ | ⚪ declared-but-unused (no owner check) | ⚪ | Ride.GetRideByID | `handler/ride.go:130` |
| GET | `/api/v1/rides/:id/receipt` | ✅ | ⚪ declared-but-unused | — | Ride.GetRideReceipt | `handler/ride.go:330` |
| POST | `/api/v1/rides/:id/cancel` | ✅ | 🟢 real call on 2 screens | ⚪ | Ride.CancelRide (`cancelled_by`) | `handler/ride.go:200` |
| POST | `/api/v1/rides/:id/rate` | ✅ | ⚪ declared-but-unused | — | Ride.RateRide | `handler/ride.go:258` |
| POST | `/api/v1/rides/:id/tip` | ❌ | ⚪ declared-but-unused | — | Ride.TipDriver | `handler/ride.go:357` |
| PUT | `/api/v1/rides/:id/destination` | ✅ | ⚪ | ⚪ | Ride.UpdateDestination (owner-only; 404/409/422/5xx) | `handler/ride.go:285` |
| GET | `/api/v1/navigation/route` | ✅ | 🟢 polyline rendered + zoom-to-fit | 🟡 trip polyline fetch + cache (plan 04 partial) | Platform.NavigationRoute (A\* road routing, 422 validation) | `handler/platform.go:402` |
| GET | `/api/v1/places/autocomplete` | ✅ | 🟢 | ⚪ | Platform.PlacesAutocomplete (PostGIS+FTS) | `handler/platform.go:169` |
| GET | `/api/v1/places/geocode` | ✅ | ⚪ not declared (manual address entry) | ⚪ | Platform.PlacesGeocode (real reverse geocode) | `handler/platform.go:235` |
| GET | `/api/v1/places/details` | ❌ | ⚪ | ⚪ | Platform.PlacesDetails | `handler/platform.go:278` |
| GET | `/api/v1/estimates/price` | 🟡 | 🟢 wired (real totals; rate fields mislabeled) | — | Platform.EstimatesPrice (fare engine) | `handler/platform.go:298` |
| GET | `/api/v1/estimates/eta` | ✅ | ⚪ | ⚪ | Platform.EstimatesETA (A\*) | `handler/platform.go:356` |
| GET | `/api/v1/promotions` | ❌ | ⚪ | ⚪ | Platform.PromotionsList (empty) | `handler/platform.go:138` |
| POST | `/api/v1/promotions/apply` | ❌ | ⚪ | ⚪ | Platform.ApplyPromotion | `handler/platform.go:150` |
| POST | `/api/v1/sos` | ❌ | ⚪ declared-but-unused | ⚪ declared-but-unused | Platform.SOS (ack only) | `handler/platform.go:52` |
| POST | `/api/v1/feedback` | ✅ | ⚪ | ⚪ driver safety screen sends `{type, message}` | Platform.Feedback (persists, echoes `type`) | `handler/platform.go` |
| POST | `/api/v1/devices` | ✅ | ⚪ app does not register a token yet | ⚪ app does not register a token yet | Platform.DeviceRegister (upsert; reassigns a globally-unique token) | `handler/platform.go` |
| DELETE | `/api/v1/devices/:token` | ✅ | ⚪ | ⚪ | Platform.DeviceUnregister (idempotent, user-scoped) | `handler/platform.go` |
| POST | `/api/v1/device-tokens` | ✅ | ⚪ | ⚪ | alias of Platform.DeviceRegister | `handler/platform.go` |
| DELETE | `/api/v1/device-tokens/:token` | ✅ | ⚪ | ⚪ | alias of Platform.DeviceUnregister | `handler/platform.go` |
| GET | `/api/v1/heatmap` | ❌ | ⚪ | ⚪ | Platform.Heatmap (placeholder PNG) | `handler/platform.go:435` |
| GET | `/api/v1/drivers/:id/location` | ✅ | ⚪ declared-but-unused | — | Geo.GetDriverLocation | `handler/geo.go:186` |
| POST | `/api/v1/driver/earnings/withdraw` | ❌ | — | ⚪ declared-but-unused | StubPayment | `handler/platform.go:497` |
| GET | `/ws` | ✅ | 🟢 `ride.updated` + `driver.location` contract aligned | 🟢 offer/updated/location consumed; accept/decline/ping sent (plans 01, 03) | WebSocket hub (offer/updated/location; accept/decline/ping) | `websocket/hub.go` |
| GET | `/docs`, `/docs/*any` | — | ⚪ | ⚪ | Swagger UI (spec source) | `router.go:220` |

**Rider app wiring summary (from `rider_app/lib`, working tree at `8a3a13f`, plans 01–03/08–11 applied):** actually invoked in code: `/auth/register`, `/auth/login`, `/auth/logout`, `/auth/refresh` (401 interceptor single-flight retry), `GET /rider/me` (cold-start auth check), `GET /geo/nearby-drivers` (provider, never rendered → dead), `GET /estimates/price`, `GET /places/autocomplete`, `POST /rides`, `GET /rides/current` (5 s poll + create fallback + splash restore), `POST /rides/:id/cancel`, `GET /navigation/route` (polyline rendered), `/ws` (listens `ride.updated` + `driver.location`). Declared in `endpoints.dart` but never invoked: `eta`, `rideById`, `rateRide`, `tipRide`, `receipt`, `driverLocation`, `paymentMethods`, `ridesHistory`, `sos`. Fake UI instead of real calls: forgot-password screen (local toggle), HistoryScreen ("No rides yet"), PaymentScreen ("coming soon"), SecurityScreen, ProfileScreen (hardcoded "Rider"/"rider@example.com"). Known render gap: `ActiveRideScreen` reads invented flat keys `driver_lat`/`driver_lng`/`driver_name`/`car_model` (`active_ride_screen.dart:109-113,173-174`) instead of the parsed typed state — driver card/marker show "Unknown Driver" on real events (US-7).

**Driver app wiring summary (from `driver_app/`, audited 2026-09-25: plans 01–05 landed, 06 🟠 untested, 07 🟠):** **21 of 31 declared** endpoints actually invoked — `/auth/register`, `/auth/login`, `/auth/refresh` (401 single-flight auto-refresh), `/auth/logout`, `/auth/forgot-password`, `/auth/reset-password`, `POST /driver/register` (promotes to the `driver` role; onboarding name fields are collected but **never sent**), `GET /driver/me` (seeded at login/refresh, rendered in profile + home), `PUT /driver/me` (profile edit, `ProfileNotifier.updateProfile`), `PUT /driver/me/status` (online/offline toggle, double-tap guarded), `PUT /geo/driver/location` (+ `PUT /geo/driver/location/batch` for buffered flushes; ≥5 s throttle, online-only pushes), `GET /driver/rides/:id` (offer detail fetch, 5 s load timeout), `POST /driver/rides/:id/accept` (HTTP fallback when the WS is dead; 409 → "Trip no longer available"), `GET /driver/rides/current` (launch restore — the WS has no replay), `PUT /driver/rides/:id/status` (trip stage transitions), `POST /driver/rides/:id/cancel` (driver-initiated, pre-`in_progress` only, confirm dialog), `GET /driver/rides/history` (1-based `page`/`per_page`, id-deduped, pull-to-refresh + infinite scroll), `POST /driver/rides/:id/rate` (1–5 stars + optional comment from the trip receipt or the history list), `GET /navigation/route` (origin = the driver's live fix, refetched past a 200 m move), `/ws` (connect for the `driver` role; `ride.offer`/`ride.updated`/`driver.location` consumed by `RideStateNotifier` → `TripNotifier`; `ride.accept`/`ride.decline`/`ping` sent; offer expiry from `offerExpiresAt`). ⚠️ Two contract corrections vs. `driver_app_plans/STATUS.md` `[history]` as first written: the rate body field is **`score`**, not `rating` (a `rating` key binds to zero and 400s), and history pagination is `page`/`per_page`, not `limit`/`offset` (out-of-range values are silently rewritten, so a bad one returns a valid-looking page). No endpoint is declared-but-dead any more.

**Still declared-but-unused (API-side status corrected):** `GET /driver/rides/queue`, `GET /driver/rides/:id/rider`, `POST /driver/rides/:id/decline` (HTTP; decline is WS-only), `POST /driver/rides/:id/notify-arrival` (**implemented** server-side; the app skips it because the status transition already notifies), `GET /driver/me/earnings`, `POST /driver/earnings/withdraw`, `GET/POST /driver/me/documents`, `POST /sos`; `GET /driver/ratings` and `POST /feedback` are now invoked by the driver app. `GET /driver/me/vehicle` has a call site but is feature-gated off. Note that `/driver/me/earnings` and `/driver/earnings/withdraw` are **stubs**, so the app's earnings card is a client-side sum over the history pages loaded so far and there is no withdraw UI at all; `GET /driver/ratings` is a real paginated read (used by `RatedRidesNotifier`), and `rating_summary` is still never recalculated. Test coverage: **224 driver tests green**, `flutter analyze` clean — the profile/settings suites now exist; the vehicle surface shipped in plan 06 still has **no tests** (its `vehicleFeatureEnabled` flag is false, so the screen is unreachable). Blueprint: `DRIVER_APP_PLAN.md` (M1–M10); per-plan status and the resume point in `driver_app_plans/STATUS.md` (07's safety screen → 06's missing suites).

**Matrix freshness:** last-applied: rider app (WS contract, real cancel, current-poll, zoom-to-fit, dropoff marker refresh, server route polyline, web/CORS ride creation, real profile/account — all condensed in `rider_app_plans/STATUS.md`); driver plans 01–05 (WS contract + ride-state, online/location loop, offer accept/decline, trip journey + navigation, history/earnings/rating) + 06 partial. Still open in `rider_app_plans/`: `[history]` ride history, `[geo]` rider-location ping, `[auth]` forgot-password, `[safety]` SOS/skip, `[tracking]` receipt/rating + live tracking (partial); in `driver_app_plans/`: 06 tests, 07 safety/support (turn-by-turn guidance stays open everywhere). An endpoint cell flips to 🟢/🟠 only after its build plan lands and `flutter test` passes; update the rider "13 targets" / driver "21 of 31" counts and any story tags together at that point.