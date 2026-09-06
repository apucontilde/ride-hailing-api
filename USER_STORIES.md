# Ride-Hailing App User Stories

Two companion apps — a **Rider app** (passenger) and a **Driver app** — both talk to the same backend (`ride-hailing-api`). This document walks the full journey of one rider booking a trip and one driver receiving and accepting that trip, expressed as concise user stories. Every API call references the OpenAPI spec at `docs/swagger.json` (browseable at `/docs`), which is the source of truth for request/response schemas.

## Conventions

- Base URL: `http://<host>:8080`; API routes live under `/api/v1`.
- Auth: `Authorization: Bearer <access_token>` on every protected call.
- Real-time: `GET /ws` (Bearer-token authenticated WebSocket). The backend pushes `ride.offer`, `ride.updated`, and `driver.location` events; the app replies with `ping` / `ride.accept` / `ride.decline`.
- Booking safety: `POST /api/v1/rides` supports replay protection via the optional `Idempotency-Key` header. The rider app should generate one UUID per booking attempt and reuse it on retries so a tap-retry never double-books; without the header the backend simply treats each request as a new booking.
- Role checks: rider endpoints require the `rider` role, driver endpoints the `driver` role (accounts are promoted via `POST /api/v1/driver/register`).
- Trip state machine: `pending → accepted → driver_arrived → in_progress → completed`; `cancelled` is allowed from `pending`, `accepted`, and `driver_arrived`. Every state change is echoed to both sides as a `ride.updated` event.

---

# Part A — Rider app (the passenger)

## US-1 Sign up
**As a** new rider, **I want** to create an account with my email/phone/password, **so that** I can book rides.

- **Screen:** Onboarding / Register
- **API:**
  - `POST /api/v1/auth/register` — body `{email, phone, password}` → `201 {user:{id,email,phone,role:"rider"}}`
- **Notes:** Register always creates the `rider` role and a rider profile. After this the app proceeds to US-2.

## US-2 Log in
**As a** rider, **I want** to log in and receive tokens, **so that** I can call authenticated endpoints and open a WebSocket.

- **Screen:** Login
- **API:**
  - `POST /api/v1/auth/login` — body `{email, password}` → `200 {access_token, refresh_token, user}`
  - `POST /api/v1/auth/refresh` — body `{refresh_token}` → new token pair when the access token expires
  - `POST /api/v1/auth/logout` — body `{refresh_token}` on sign-out
- **Notes:** Store tokens securely; attach `Authorization: Bearer` to all subsequent calls.

## US-3 Set pickup & destination
**As a** a rider, **I want** to enter or search my destination and confirm my pickup, **so that** the app knows where to send the driver.

- **Screens:** Home (map) / Search
- **API:**
  - `PUT /api/v1/geo/rider/location` — body `{lat, lng}` → `204` (broadcast current position)
  - `GET /api/v1/places/autocomplete?lat=&lng=&q=&radius=&limit=` — search nearby addresses/POIs → `{places:[...]}`
- **Notes:** `places/geocode` (map-pin → address) and `places/details` are stubs — see Part C. Fall back to manual address entry until then.

## US-4 See the price & ETA estimate
**As a** a rider, **I want** to preview the fare and ETA before confirming, **so that** I can decide whether to book.

- **Screen:** Confirm / Estimate
- **API:**
  - `GET /api/v1/estimates/price` → `{estimates:[{vehicle_type, base_fare, distance_rate, time_rate}]}`
  - `GET /api/v1/estimates/eta` → `{eta_seconds, distance_meters}` (static stub today)
- **Notes:** `estimates/eta` and `geo/eta` return placeholder values; real ETA per driver is a Part C gap.

## US-5 Request the trip
**As a** rider, **I want** to confirm the ride, **so that** nearby drivers are dispatched to my pickup.

- **Screen:** Confirm ride
- **API:**
  - `POST /api/v1/rides` — optional header `Idempotency-Key: <uuid>` (replay protection), body `{pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, pickup_address, dropoff_address, vehicle_type}` → `201 {ride:{..., status:"pending"}}`
  - WebSocket: server pushes `ride.updated` with `status:"pending"` (+ pickup/dropoff) to the rider's `/ws` connection.
- **Notes:** Fare is calculated server-side from the route (base + distance + time + surge). Retries should reuse the same `Idempotency-Key`.

## US-6 Wait for a driver
**As a** rider, **I want** to see the searching state and driver availability, **so that** I know the request is live.

- **Screen:** Searching for driver
- **API:**
  - WebSocket: keep `/ws` open; watch for `ride.updated` → `status:"accepted"` or `status:"no_driver_available"`.
  - `GET /api/v1/rides/current` → `{ride|null}` (poll fallback if WS drops)
- **Notes:** The backend dispatches sequentially to drivers within expanding radii (500 m → 10 km), offering to at most 5 drivers and waiting up to 30 s per driver. Only drivers with a live `/ws` connection receive offers. If none accept, the ride becomes `no_driver_available`.

## US-7 Track the matched driver
**As a** rider, **I want** to see my driver's info, vehicle, and live location, **so that** I know who is coming and when.

- **Screen:** Driver on the way
- **API:**
  - WebSocket: `ride.updated` → `status:"accepted"` carries `driver {id, first_name, photo_url, rating, vehicle, location}` and `eta_seconds`.
  - WebSocket: `driver.location` events stream the driver's position during the trip.
  - `GET /api/v1/drivers/:id/location` → `{lat, lng, heading, speed, ...}` (polling fallback)
- **Notes:** Live driver telemetry is only pushed while the driver is streaming `PUT /api/v1/geo/driver/location`.

## US-8 Ride in progress
**As a** rider, **I want** to follow the trip and see the route, **so that** I can plan my time and feel informed.

- **Screen:** Active trip
- **API:**
  - WebSocket: `ride.updated` → `status:"driver_arrived"`, then `status:"in_progress"`.
  - `GET /api/v1/navigation/route?from_lat=&from_lng=&to_lat=&to_lng=` → `{polyline, total_distance_m, total_duration_s}`
  - `GET /api/v1/rides/:id` → full ride object (authoritative state)
- **Notes:** Arrival/destination updates mid-trip are stubbed (`PUT /api/v1/rides/:id/destination`) — see Part C.

## US-9 Trip complete & fare
**As a** rider, **I want** to see the final fare breakdown when the trip ends, **so that** I can review charges.

- **Screen:** Fare / Receipt
- **API:**
  - WebSocket: `ride.updated` → `status:"completed"` includes `fare {base_fare, distance_fare, time_fare, surge_multiplier, total}`.
  - `GET /api/v1/rides/:id/receipt` → `{receipt:{base_fare, distance_fare, time_fare, surge_multiplier, total}}`
- **Notes:** Completion applies an actual-trip multiplier; the receipt endpoint is the durable record.

## US-10 Rate the driver
**As a** rider, **I want** to rate and optionally comment on the driver after the trip, **so that** the community gets better service.

- **Screen:** Rating
- **API:**
  - `POST /api/v1/rides/:id/rate` — body `{score: 1..5, comment}` → `200 {message:"rating submitted"}`

## US-11 Cancel a ride
**As a** rider, **I want** to cancel before the driver picks me up, **so that** I can change plans.

- **Screen:** Any pre-trip screen
- **API:**
  - `POST /api/v1/rides/:id/cancel` → `200 {ride:{status:"cancelled"}}`
  - WebSocket: both rider and driver receive `ride.updated` → `status:"cancelled"` with `cancelled_by:"rider"`.
- **Notes:** Only allowed in `pending`, `accepted`, or `driver_arrived`. `cancellation_fee` exists on the model but is never charged — see Part C.

## US-12 Safety — send an SOS
**As a** rider, **I want** to trigger an emergency alert from the trip screen, **so that** help can be dispatched if something goes wrong.

- **Screen:** Safety / SOS
- **API:**
  - `POST /api/v1/sos` — body `{lat, lng}` → `201 {message, alert:{...}}`
- **Notes:** Today this only returns an acknowledgment and is **not persisted** or dispatched — see Part C.

## US-13 Profile & devices
**As a** rider, **I want** to view/edit my profile and register my device, **so that** my details and push notifications are correct.

- **Screens:** Profile / Settings
- **API:**
  - `GET /api/v1/rider/me` → `{user, rider}`
  - `PUT /api/v1/rider/me` — body `{first_name, last_name, photo_url, phone?}`
  - `PUT /api/v1/rider/me/status` — body `{status}`
  - `POST /api/v1/devices` — body `{token, platform}` (push registration)
  - `DELETE /api/v1/devices/:token` on app uninstall

## US-14 Ride history
**As a** rider, **I want** a paginated list of past trips, **so that** I can re-book or reference them.

- **Screen:** History
- **API:**
  - `GET /api/v1/rides/history?page=1&per_page=20` → `{rides, total, page, per_page, total_pages}`

---

# Part B — Driver app (the driver)

## US-D1 Create a driver account
**As a** driver, **I want** to create an account and register as a driver, **so that** I can start receiving ride requests.

- **Screens:** Onboarding → Driver registration
- **API:**
  - `POST /api/v1/auth/register` — body `{email, phone, password}` → creates the account in the `rider` role
  - `POST /api/v1/driver/register` (auth) → `201 {driver:{status:"offline", onboarding_status:"documents_submitted"}}` promotes the user to `driver`
- **Notes:** After promotion the account holds the `driver` role, so the driver app uses the driver endpoints.

## US-D2 Log in
**As a** driver, **I want** to log in and get tokens, **so that** I can go online and connect to live offers.

- **Screen:** Login
- **API:**
  - `POST /api/v1/auth/login` → `200 {access_token, refresh_token, user}`
  - `POST /api/v1/auth/refresh` on token expiry; `POST /api/v1/auth/logout` on sign-out

## US-D3 Set up profile & vehicle
**As a** driver, **I want** to add my name/photo and vehicle details, **so that** riders see who is coming for them.

- **Screen:** Profile / Vehicle
- **API:**
  - `GET /api/v1/driver/me` → `{driver:{..., vehicle}}` and `PUT /api/v1/driver/me` — body `{first_name, last_name, photo_url}`
  - `GET /api/v1/driver/me/vehicle` / `PUT /api/v1/driver/me/vehicle` — **stub today** (Part C)
- **Notes:** The vehicle (make/model/color/plate) is what riders see in the `ride.updated` `driver.vehicle` payload, so this must be real before launch.

## US-D4 Go online
**As a** driver, **I want** to set myself online and start broadcasting my location, **so that** the dispatcher can offer me rides.

- **Screen:** Home / Availability
- **API:**
  - `PUT /api/v1/driver/me/status` — body `{status:"online"}` (use `"offline"` to stop)
  - `PUT /api/v1/geo/driver/location` — body `{lat, lng, heading, speed}` → `204` (stream periodically; batch via `PUT /api/v1/geo/driver/location/batch`)
  - `GET /ws` — open the authenticated WebSocket to receive offers
- **Notes:** Dispatch only offers rides to drivers whose `/ws` connection is live (`hub.IsConnected`), so online + WS + location must all be active.

## US-D5 Receive a ride request
**As a** driver, **I want** to see an incoming trip offer with the key details, **so that** I can decide whether to take it.

- **Screen:** Ride offer
- **API:**
  - WebSocket: `ride.offer` → `{ride_id}` (the offer payload only carries the id today)
  - `GET /api/v1/driver/rides/:id` → full ride `{pickup_lat/lng/address, dropoff..., vehicle_type, status:"pending", fares}`
- **Notes:** Offer context (distance to pickup, fare, TTL) is fetched with a second call now; a richer offer payload is a Part C improvement.

## US-D6 Accept the ride
**As a** driver, **I want** to accept a matching offer, **so that** the rider is notified and the trip moves to `accepted`.

- **Screen:** Ride offer
- **API:**
  - Primary (live): WebSocket message `ride.accept` → `{ride_id}`; the hub assigns the driver.
  - Fallback/HTTP: `POST /api/v1/driver/rides/:id/accept` → `200 {message:"ride accepted"}` or `409` if another driver already took it.
  - WebSocket: both driver and rider receive `ride.updated` → `status:"accepted"` with driver info + `eta_seconds:300`.
- **Notes:** Declining uses WebSocket `ride.decline` → `{ride_id}` (the HTTP `POST /api/v1/driver/rides/:id/decline` is a stub). Offers expire after 30 s.

## US-D7 Navigate to the pickup
**As a** driver, **I want** turn-by-turn guidance to the pickup point, **so that** I arrive efficiently.

- **Screen:** Navigation
- **API:**
  - `GET /api/v1/navigation/route?from_lat=&from_lng=&to_lat=&to_lng=` → `{polyline, total_distance_m, total_duration_s}`

## US-D8 Arrived at pickup
**As a** driver, **I want** to mark that I arrived and notify the rider, **so that** the rider comes out.

- **Screen:** Arrival
- **API:**
  - `PUT /api/v1/driver/rides/:id/status` — body `{status:"driver_arrived"}`
  - `POST /api/v1/driver/rides/:id/notify-arrival` → `200 {message}` (**stub** — no push is actually sent)
  - WebSocket: rider sees `ride.updated` → `status:"driver_arrived"`
- **Notes:** A real "notify the rider" push depends on the missing push-delivery pipeline (Part C).

## US-D9 Start and complete the trip
**As a** driver, **I want** to start the trip when the rider is onboard and complete it at the destination, **so that** the fare is finalized.

- **Screen:** Active trip
- **API:**
  - `PUT /api/v1/driver/rides/:id/status` — body `{status:"in_progress"}`, then `{status:"completed"}`
  - WebSocket: both sides get `ride.updated` → `in_progress`, then `completed` (with the final `fare`).
- **Notes:** Only the assigned driver may advance status; transitions outside the state machine are rejected with `400`.

## US-D10 Rate the rider
**As a** driver, **I want** to rate the rider after the trip, **so that** rider quality is tracked.

- **Screen:** Rating
- **API:**
  - `POST /api/v1/driver/rides/:id/rate` — body `{score: 1..5, comment}` → `200 {message}`

## US-D11 View history & earnings
**As a** driver, **I want** to see my ride history and earnings, **so that** I can track my income.

- **Screen:** Earnings / History
- **API:**
  - `GET /api/v1/driver/rides/history?page=1&per_page=20` → `{rides, total, page, per_page, total_pages}`
  - `GET /api/v1/driver/rides/current` → `{ride|null}` (check if a trip is active)
  - `GET /api/v1/driver/me/earnings` — **stub** (Part C)
- **Notes:** Withdrawals (`POST /api/v1/driver/earnings/withdraw`) are also stubbed.

---

# Part C — Missing / stubbed endpoints to build later

Everything below is either a stub today or absent from the spec, and is needed to complete the flows above.

### Required to finish the core booking trip (US-3 → US-12)

| Endpoint | Status | Needed for |
|---|---|---|
| `GET /api/v1/places/geocode?lat=&lng=` | stub | Reverse-geocode a map pin to an address on the Home screen (US-3) |
| `GET /api/v1/places/details?id=` | stub | Address/place details for a search result (US-3) |
| `GET /api/v1/estimates/eta` and `GET /api/v1/geo/eta` | static stub | Real, per-request ETA shown before booking and while waiting (US-4, US-6) |
| `GET /api/v1/driver/rides/:id/rider` | stub | Real rider name/rating/photo for the driver after accepting (US-D6) |
| `PUT /api/v1/rides/:id/destination` | stub | Change destination / add a stop mid-trip (US-8) |
| `POST /api/v1/sos` | returns ack only | Persist the alert and dispatch it to emergency contacts/support (US-12) |
| `POST /api/v1/feedback` | returns ack only | Persist feedback so it can be triaged |

### Payment & post-trip money

| Endpoint | Status | Needed for |
|---|---|---|
| `POST /api/v1/rides/:id/tip` | stub | Let the rider tip the driver (US-10) |
| `GET/POST/DELETE /api/v1/rider/payment-methods` (+ `/:id`) | stub | Rider card/wallet management; a precondition for real tipping and fare charging |
| Cancellation-fee charge | missing | `cancellation_fee` exists on the ride model but no endpoint computes/charges it (US-11) |

### Driver onboarding & money (US-D3, US-D11)

| Endpoint | Status | Needed for |
|---|---|---|
| `GET/PUT /api/v1/driver/me/vehicle` | stub | Vehicle CRUD; riders see the vehicle in `ride.updated`, so this must be real before launch |
| `GET/POST /api/v1/driver/me/documents` | stub | Document upload + verification/approval workflow for onboarding |
| `GET /api/v1/driver/me/earnings` | stub | Earnings dashboard |
| `POST /api/v1/driver/earnings/withdraw` | stub | Payout requests |
| `GET /api/v1/driver/ratings` and `GET /api/v1/rider/ratings` | stub | Rating breakdown screens |

### Offers & dispatch UX

| Endpoint | Status | Needed for |
|---|---|---|
| `POST /api/v1/driver/rides/:id/decline` | stub (WS works) | HTTP decline with an optional reason |
| `GET /api/v1/driver/rides/queue` | stub | Offline/missed-offer queue for drivers |
| Richer `ride.offer` payload | missing | Include pickup/dropoff, fare, distance-to-pickup, and an expiry TTL so the driver can decide without a follow-up `GET /driver/rides/:id` (US-D5) |

### Account & engagement (nice-to-have)

| Endpoint | Status | Needed for |
|---|---|---|
| `GET/POST/DELETE /api/v1/rider/favorites` (+ `/:id`) | stub | Saved places for one-tap booking |
| `GET/PUT /api/v1/rider/me/preferences` | stub | Rider preferences |
| `GET /api/v1/promotions`, `POST /api/v1/promotions/apply` | stub | Discount codes at booking |
| `POST /api/v1/auth/social` | stub | Google/Apple OAuth sign-in (US-1/US-D1) |
| `GET /api/v1/geo/isochrone`, `GET /api/v1/heatmap` | stub | Demand analytics for drivers |
| Push delivery pipeline | missing (only device registration exists) | Actually delivering `notify-arrival` and ride updates when the app is backgrounded |

### Cross-cutting gaps

- **Ride offers are only delivered while the driver keeps `/ws` open** — without push delivery, a driver with the app in the background will miss offers (ties into the push pipeline above).
- **No admin endpoints** — there is no dashboard for support to resolve SOS alerts, verify documents, or review feedback.
- **Real ETA** — `eta_seconds` is hard-coded (`300`) in the accept event; it should come from routing + driver position.
