# Rider API Guide

This guide lists the currently exposed API surface. It is rider-focused, but it also includes shared platform, driver, and websocket endpoints because the backend exposes them today.

## Conventions

- Base API URL: `http://<host>:8080/api/v1`
- Public non-API endpoints: `GET /health`, `GET /health/ready`, `GET /ws`
- Auth header for protected routes: `Authorization: Bearer <access_token>`
- Error shape:

```json
{ "error": { "code": "UNAUTHORIZED", "message": "..." } }
```

## Errors

Every non-2xx response body is the same envelope:

```json
{ "error": { "code": "<CODE>", "message": "<string>" } }
```

- `message` is **user-facing** and safe to render verbatim. It never contains SQL, driver
  text, Go identifiers, or internal hints.
- Error codes and what each means for a client:
  - `VALIDATION_ERROR` (422) — the request has a fixable problem (a missing or malformed field).
  - `BAD_REQUEST` (400) — the body could not be read as JSON.
  - `UNAUTHORIZED` (401) — credentials are missing, invalid, or expired.
  - `NOT_FOUND` (404) — the requested resource does not exist.
  - `CONFLICT` (409) — the request conflicts with existing state (e.g. email already taken).
  - `INTERNAL` (500) — our failure. The rider app's straight-line fallback triggers on
    **any** error status, not only here — which is exactly why an outage must never be
    classified as a 4xx.
- 4xx means **the caller can fix it by changing something**; 5xx means **we are broken**. A
  client must not retry a 4xx and must not treat a 5xx as final. A backend failure is **never**
  a 4xx.
- A route returned with `200` and `is_estimate: true` is **not** an error — it is a
  straight-line estimate for coordinates outside every imported routing region.
- A write that fails answers 5xx, never the endpoint's success code (including the batch
  location endpoint, where one rejected item fails the whole request).
- Audit rows and the idempotency store are best-effort and invisible: a failure writing them is
  logged and the response is unchanged.

## Public Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/health` | No | Liveness check, returns `{ "status": "ok" }` |
| GET | `/health/ready` | No | Readiness check, includes database status |
| GET | `/api/v1/version` | No | Returns app version and commit |

## Auth

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/auth/register` | No | Creates a rider account and rider profile |
| POST | `/api/v1/auth/login` | No | Returns access and refresh tokens |
| POST | `/api/v1/auth/refresh` | No | Rotates refresh token and returns a new pair |
| POST | `/api/v1/auth/logout` | Yes | Revokes the refresh token in the body |
| POST | `/api/v1/auth/forgot-password` | No | Returns a reset token when the email exists |
| POST | `/api/v1/auth/reset-password` | No | Resets password with a reset token |
| POST | `/api/v1/auth/verify-email` | Yes | Accepts a code and marks email verified |
| POST | `/api/v1/auth/verify-phone` | Yes | Accepts a code and marks phone verified |
| POST | `/api/v1/auth/social` | No | Stub: social login not implemented |

### Auth payloads

Register:

```json
{
  "email": "rider@example.com",
  "phone": "+5511999999999",
  "password": "SecurePass1"
}
```

Login:

```json
{
  "email": "rider@example.com",
  "password": "SecurePass1"
}
```

Refresh/logout:

```json
{ "refresh_token": "..." }
```

Forgot password:

```json
{ "email": "rider@example.com" }
```

Reset password:

```json
{
  "token": "...",
  "new_password": "NewSecure1"
}
```

Verify email/phone:

```json
{ "code": "123456" }
```

## Rider Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/v1/rider/me` | Yes, role rider | Returns sanitized user plus rider profile |
| PUT | `/api/v1/rider/me` | Yes, role rider | Updates rider profile; phone is optional |
| PUT | `/api/v1/rider/me/status` | Yes, role rider | Updates rider status |
| DELETE | `/api/v1/rider/me` | Yes, role rider | Soft-deletes the account |
| GET | `/api/v1/rider/me/preferences` | Yes, role rider | Stub |
| PUT | `/api/v1/rider/me/preferences` | Yes, role rider | Stub |
| GET | `/api/v1/rider/ratings` | Yes, role rider | Paginated ratings the rider submitted |
| GET | `/api/v1/rider/favorites` | Yes, role rider | Stub |
| POST | `/api/v1/rider/favorites` | Yes, role rider | Stub |
| DELETE | `/api/v1/rider/favorites/:id` | Yes, role rider | Stub |
| GET | `/api/v1/rider/payment-methods` | Yes, role rider | Stub |
| POST | `/api/v1/rider/payment-methods` | Yes, role rider | Stub |
| DELETE | `/api/v1/rider/payment-methods/:id` | Yes, role rider | Stub |

### Rider profile examples

Update profile:

```json
{
  "first_name": "John",
  "last_name": "Doe",
  "photo_url": "https://...",
  "phone": "+5511999999999"
}
```

Update status:

```json
{ "status": "active" }
```

## Driver Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/driver/register` | Yes | Promotes the current user to driver and creates a driver profile |
| GET | `/api/v1/driver/me` | Yes, role driver | Returns driver profile |
| PUT | `/api/v1/driver/me` | Yes, role driver | Updates driver profile |
| PUT | `/api/v1/driver/me/status` | Yes, role driver | Updates driver status |
| GET | `/api/v1/driver/me/documents` | Yes, role driver | Stub |
| POST | `/api/v1/driver/me/documents` | Yes, role driver | Stub |
| GET | `/api/v1/driver/me/vehicle` | Yes, role driver | Stub |
| PUT | `/api/v1/driver/me/vehicle` | Yes, role driver | Stub |
| GET | `/api/v1/driver/me/earnings` | Yes, role driver | Stub |
| GET | `/api/v1/driver/ratings` | Yes, role driver | Paginated ratings the driver submitted |
| POST | `/api/v1/driver/earnings/withdraw` | Yes, role driver | Stub |

## Driver Ride Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/v1/driver/rides/current` | Yes, role driver | Returns the driver current ride or null |
| GET | `/api/v1/driver/rides/history` | Yes, role driver | Paginated history |
| GET | `/api/v1/driver/rides/queue` | Yes, role driver | Stub |
| GET | `/api/v1/driver/rides/:id` | Yes, role driver | Returns ride by ID |
| GET | `/api/v1/driver/rides/:id/rider` | Yes, role driver | Stub |
| POST | `/api/v1/driver/rides/:id/accept` | Yes, role driver | Accepts a dispatched ride |
| POST | `/api/v1/driver/rides/:id/decline` | Yes, role driver | Stub at HTTP level; websocket decline is handled by the hub |
| PUT | `/api/v1/driver/rides/:id/status` | Yes, role driver | Advances ride status |
| POST | `/api/v1/driver/rides/:id/cancel` | Yes, role driver | Cancels ride when allowed |
| POST | `/api/v1/driver/rides/:id/rate` | Yes, role driver | Rates the rider |
| POST | `/api/v1/driver/rides/:id/notify-arrival` | Yes, role driver | Sends a live `ride.updated` (`driver_arrived`) to a connected rider, or a backgrounded push when the rider is offline. Ancillary: it does not change the stored status. 404 for another driver's / an unknown ride |

## Ride Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/rides` | Yes, role rider | Creates a ride, idempotent with `Idempotency-Key` |
| GET | `/api/v1/rides/current` | Yes | Returns the current ride plus its `stops`, or `ride: null` |
| GET | `/api/v1/rides/history` | Yes | Paginated history for rider or driver, plus each ride's `stops` |
| GET | `/api/v1/rides/:id` | Yes | Returns ride by ID |
| GET | `/api/v1/rides/:id/receipt` | Yes | Returns fare breakdown |
| POST | `/api/v1/rides/:id/cancel` | Yes | Cancels ride when state allows it |
| POST | `/api/v1/rides/:id/rate` | Yes | Rates the other party |
| POST | `/api/v1/rides/:id/tip` | Yes | Stub |
| PUT | `/api/v1/rides/:id/destination` | Yes, role rider | Changes the destination of a ride that is still open |

### Create ride body

```json
{
  "pickup_lat": -23.5505,
  "pickup_lng": -46.6333,
  "dropoff_lat": -23.561,
  "dropoff_lng": -46.656,
  "pickup_address": "Av. Paulista, 1000",
  "dropoff_address": "Rua Augusta, 500",
  "vehicle_type": "sedan",
  "stops": [
    { "lat": -23.5555, "lng": -46.6444, "address": "Shopping Paulista" }
  ]
}
```

`vehicle_type` defaults to `sedan`.

### Multi-stop rides

`stops` is **optional and additive**: a body without it behaves exactly as before,
so an older client keeps working unchanged.

- The array **is** the visit order. Do not send a sequence number — it is derived
  from the array position and returned as `sequence` (1-based).
- `lat` and `lng` are both required on every stop. `0` is a valid coordinate, so
  an absent coordinate is a `422`, not a default.
- `kind` is optional and defaults to `stop`; the only accepted value is `stop`
  (or omitted). A client stop with `kind: "destination"` is rejected as a `422`
  — the final destination is defined solely by the top-level `dropoff_lat`/
  `dropoff_lng`/`dropoff_address`.
- The ride's own `dropoff_lat`/`dropoff_lng`/`dropoff_address` are **always**
  appended as the final `destination` stop, so `stops` always ends in exactly one
  destination and the ride's `dropoff_*` scalars can never disagree with it.
- `stops` are the intermediate waypoints only; the pickup point is never a stop
  (it stays in the `pickup_*` fields).

`POST /api/v1/rides` and `GET /api/v1/rides/:id` answer with `stops` next to
`ride`:

```json
{
  "ride": { "id": "…", "status": "pending", "…": "unchanged" },
  "stops": [
    { "id": "…", "ride_id": "…", "sequence": 1, "kind": "stop",
      "lat": -23.5555, "lng": -46.6444, "address": "Shopping Paulista" },
    { "id": "…", "ride_id": "…", "sequence": 2, "kind": "destination",
      "lat": -23.561, "lng": -46.656, "address": "Rua Augusta, 500" }
  ]
}
```

`stops` is always an array, never `null`. For a ride created before multi-stop,
or one with no intermediate stops, it holds only the destination.

A rejected itinerary is a `422 VALIDATION_ERROR` naming the offending stop, e.g.
`"stop 2: the final destination is set by dropoff_lat/dropoff_lng/dropoff_address, not by a stop"`.

Every ride read carries its itinerary, so the same ride never looks
multi-stop in one response and single-leg in another:

| Endpoint | Where `stops` appears |
|---|---|
| `POST /api/v1/rides` | sibling of `ride` |
| `GET /api/v1/rides/:id` | sibling of `ride` |
| `PUT /api/v1/rides/:id/destination` | sibling of `ride` |
| `GET /api/v1/rides/current` | sibling of `ride`, `[]` when `ride` is `null` |
| `GET /api/v1/rides/history` | sibling **map** of ride id → itinerary, fetched in one query |

For history, `rides` is still the flat array it always was; the itineraries come
alongside it keyed by ride id:

```json
{
  "rides": [ { "id": "…", "…": "unchanged" } ],
  "total": 1, "page": 1, "per_page": 20, "total_pages": 1,
  "stops": { "…ride id…": [ { "sequence": 1, "kind": "destination", "…": "…" } ] }
}
```

`GET /api/v1/rides/:id/receipt` is unchanged: it is a fare breakdown, not an
itinerary.

### Change destination

`PUT /api/v1/rides/:id/destination` — rider only, and only the rider who owns the
ride.

```json
{ "lat": -23.57, "lng": -46.66, "address": "Vila Madalena" }
```

Both `lat` and `lng` are required; `address` is optional and omitted means empty.

The response is the same `{ "ride": …, "stops": […] }` envelope as above, with the
destination stop moved to the new coordinates.

What it does **not** do:

- It does not change the ride status. Allowed while `pending`, `accepted`,
  `driver_arrived` or `in_progress`; afterwards it is a `409 CONFLICT`.
- It does not reprice the ride. The booking-time estimate is what the receipt
  pays out, so a destination change never moves `total_fare`.
- It does not re-route. Route cost stays in meters and the routing contract is
  frozen, so **re-request `GET /api/v1/navigation/route`** for the new leg.

Someone else's ride answers `404` (not `403`, so ride existence is not confirmed),
and an unknown ride answers `404` too. A database outage answers `500`, never a
`4xx` — see `## Errors`.

Both parties then receive a `ride.updated` websocket message carrying the new
dropoff with `status` unchanged.

### Ride status flow

`pending -> accepted -> driver_arrived -> in_progress -> completed`

`cancelled` is allowed from `pending`, `accepted`, or `driver_arrived`.

On ride creation, the backend also sends a `ride.updated` websocket event with `status: pending` and starts dispatching nearby drivers.

### Submitted ratings

`GET /api/v1/rider/ratings` and `GET /api/v1/driver/ratings` return the
authenticated user's own submitted ratings (newest first), scoped to their role.
Pagination is `page`/`per_page` (1-based, `per_page` max 50). `ride_id` is the
key the apps use to mark a ride as already rated.

```json
{
  "ratings": [
    { "id": "…", "ride_id": "…", "rater_role": "rider", "score": 5, "comment": "Smooth", "created_at": "2026-09-30T12:00:00Z" }
  ],
  "total": 1,
  "page": 1,
  "per_page": 20,
  "total_pages": 1
}
```

A repository failure answers `500 INTERNAL` with `"failed to load ratings"`.

## Geo Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| PUT | `/api/v1/geo/driver/location` | Yes, role driver | Upserts driver location and pushes `driver.location` to the active rider |
| PUT | `/api/v1/geo/driver/location/batch` | Yes, role driver | Batch location upsert |
| PUT | `/api/v1/geo/rider/location` | Yes, role rider | Upserts rider location |
| GET | `/api/v1/geo/nearby-drivers` | Yes | Returns nearby drivers |
| GET | `/api/v1/geo/eta` | Yes | Route-based ETA `{eta_seconds, distance_meters}` (same handler as `estimates/eta`) |
| GET | `/api/v1/geo/isochrone` | Yes | Stub |

Nearby drivers query:

```text
GET /api/v1/geo/nearby-drivers?lat=-23.5505&lng=-46.6333&radius=5000&limit=20
```

## Navigation, Places, Estimates, Promotions

| Method | Path | Auth | Notes |
|---|---|---|---|
| GET | `/api/v1/navigation/route` | Yes | Returns route polyline, distance, and duration |
| GET | `/api/v1/places/autocomplete` | Yes | Real PostGIS + full-text search over OSM-seeded places |
| GET | `/api/v1/places/geocode` | Yes | Stub |
| GET | `/api/v1/places/details` | Yes | Stub |
| GET | `/api/v1/estimates/price` | Yes | Real fare engine (base + distance + time + surge over route) |
| GET | `/api/v1/estimates/eta` | Yes | Route-based ETA `{eta_seconds, distance_meters}` |
| GET | `/api/v1/promotions` | Yes | Stub |
| POST | `/api/v1/promotions/apply` | Yes | Stub |

### Navigation query

```text
GET /api/v1/navigation/route?from_lat=...&from_lng=...&to_lat=...&to_lng=...
```

Response shape:

```json
{
  "polyline": [{ "lat": 0, "lng": 0 }],
  "total_distance_m": 1234,
  "total_duration_s": 112,
  "is_estimate": false
}
```

`is_estimate` is `true` when the pickup/dropoff fall outside every imported routing region
(`ROUTING_SNAP_RADIUS_M` gate); the polyline is then the straight line between the pins and
the distance is the haversine of it.

**A route failure is always a `5xx`, never a `4xx`.** Two different situations are
deliberately kept apart: a gap in the imported road data — no imported region covers the
pins, or they are further than `ROUTING_SNAP_RADIUS_M` from any road — answers `200`
with `is_estimate: true` and a straight polyline, while a failure of the routing layer
itself (no road network imported, datasource or database unreachable) answers
`500 INTERNAL` with `"failed to calculate route"`. ⚠️ Only the 5xx half of that split is
pinned by a regression test today (`TestRouteCalculationFailureIs500Not4xx`,
`tests/error_contract_test.go:171`); the `is_estimate` half has a known defect under
repair, so an uncovered pin can currently surface as a `5xx` instead of an estimate. A
client must therefore treat `is_estimate` as a per-response flag it checks, not as a
promise the API makes for every out-of-coverage pin — and must still handle a `5xx` as
"no road route available".

The reason for the 5xx-not-4xx rule is the clients: both apps treat *any* error status as a
route failure, so a route outage misreported as a `4xx` is indistinguishable from a legitimate
client error. The driver app draws a straight line dashed (`driver_app/lib/features/trip/presentation/trip_screen.dart:285-294`,
for both a failed request and an `is_estimate` answer). The rider app now draws a grey dashed
line and surfaces the message + a Retry (`rider_app/lib/features/home/presentation/home_screen.dart:179-195,440-474`),
so an outage is no longer silent; the remaining honesty gap (the error branch still synthesizes
a line instead of showing nothing, and `is_estimate` uses client geometry) is tracked by
`rider_app_plans/[map]_route_failure_honesty.md`.

## Platform and Utility

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/sos` | Yes | Creates an SOS response payload, but it is not persisted |
| POST | `/api/v1/feedback` | Yes | Persists the feedback and echoes it, including the client `type` |
| POST | `/api/v1/devices` (alias `/api/v1/device-tokens`) | Yes | Upserts a push device token; a token is globally unique and moves to the account that registers it last |
| DELETE | `/api/v1/devices/:token` (alias `/api/v1/device-tokens/:token`) | Yes | Deactivates the caller's own token; idempotent |
| GET | `/api/v1/heatmap` | Yes | Stub |
| GET | `/api/v1/drivers/:id/location` | Yes | Returns current driver location |
| GET | `/api/v1/version` | No | App version metadata |

### Feedback body

```json
{
  "type": "app_issue",
  "message": "The app crashed on the trip screen",
  "ride_id": "optional-ride-uuid"
}
```

`type` is optional (a client that omits it stores `""`). The response echoes the persisted row:

```json
{ "message": "feedback submitted", "feedback": { "id": "…", "type": "app_issue", "message": "…", "created_at": "…" } }
```

### Device body

```json
{
  "token": "device-token",
  "platform": "ios"
}
```

`platform` must be `ios`, `android`, or `web` (anything else is a 422). A device token identifies one install, so it is globally unique: registering a token that another account already holds **reassigns** it, and the previous account stops receiving its notifications. A push is only sent to a backgrounded client; a connected WebSocket still gets `ride.updated` live.

### SOS body

```json
{
  "lat": -23.5505,
  "lng": -46.6333
}
```

## WebSocket

Endpoint: `GET /ws`

Auth: Bearer token required before upgrade.

### Client -> server messages

| Type | Notes |
|---|---|
| `ping` | Server replies with `{ "type": "pong" }` |
| `ride.accept` | Driver only; used to accept a dispatched offer |
| `ride.decline` | Driver only; used to decline a dispatched offer |

### Server -> client messages

| Type | Notes |
|---|---|
| `ride.offer` | Sent to connected drivers during dispatch |
| `ride.updated` | Sent on ride create, accept, cancel, status changes, completion, and a destination change |
| `driver.location` | Sent to the rider during an active ride |
| `pong` | Reply to `ping` |

## Current Behavior Notes

- `POST /api/v1/auth/social` is exposed but returns a not-yet-implemented response.
- `POST /api/v1/rides/:id/tip`, `GET /api/v1/geo/isochrone`, `GET /api/v1/places/*`, `GET /api/v1/promotions`, `POST /api/v1/promotions/apply`, and several rider/driver profile extras are stubs.
- `POST /api/v1/rides` calculates fare using the current fare service, including distance, time, and surge heuristics.
- `POST /api/v1/driver/rides/:id/accept` is the HTTP accept path; websocket `ride.accept` is the live driver channel used by dispatch.
- If dispatch finds no driver, the ride can move to `no_driver_available`.
- Backgrounded push is best-effort: `POST /api/v1/devices` registers the token, and ride status changes (`driver_arrived`, `in_progress`, `completed`, `cancelled`) are pushed only when the rider has no live `/ws` socket. A push that cannot be delivered is logged and never fails the ride transition. With no provider credentials configured the default is a log-and-continue no-op.

## Recommended Rider Flow

1. Register or login.
2. Connect to `GET /ws` with the access token.
3. Update rider location if needed.
4. Request a ride with `POST /api/v1/rides`.
5. Wait for `ride.updated` and `driver.location` websocket events.
6. Track the ride with `GET /api/v1/rides/current` or `GET /api/v1/rides/:id`.
7. Rate the ride after completion.
