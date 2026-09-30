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
  - `INTERNAL` (500) — our failure. The rider app's straight-line fallback triggers here and only here.
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
| GET | `/api/v1/rider/ratings` | Yes, role rider | Stub |
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
| GET | `/api/v1/driver/ratings` | Yes, role driver | Stub |
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
| POST | `/api/v1/driver/rides/:id/notify-arrival` | Yes, role driver | Stub |

## Ride Endpoints

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/rides` | Yes, role rider | Creates a ride, idempotent with `Idempotency-Key` |
| GET | `/api/v1/rides/current` | Yes | Returns the current ride for the authenticated user |
| GET | `/api/v1/rides/history` | Yes | Paginated history for rider or driver |
| GET | `/api/v1/rides/:id` | Yes | Returns ride by ID |
| GET | `/api/v1/rides/:id/receipt` | Yes | Returns fare breakdown |
| POST | `/api/v1/rides/:id/cancel` | Yes | Cancels ride when state allows it |
| POST | `/api/v1/rides/:id/rate` | Yes | Rates the other party |
| POST | `/api/v1/rides/:id/tip` | Yes | Stub |
| PUT | `/api/v1/rides/:id/destination` | Yes | Stub |

### Create ride body

```json
{
  "pickup_lat": -23.5505,
  "pickup_lng": -46.6333,
  "dropoff_lat": -23.561,
  "dropoff_lng": -46.656,
  "pickup_address": "Av. Paulista, 1000",
  "dropoff_address": "Rua Augusta, 500",
  "vehicle_type": "sedan"
}
```

`vehicle_type` defaults to `sedan`.

### Ride status flow

`pending -> accepted -> driver_arrived -> in_progress -> completed`

`cancelled` is allowed from `pending`, `accepted`, or `driver_arrived`.

On ride creation, the backend also sends a `ride.updated` websocket event with `status: pending` and starts dispatching nearby drivers.

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
the distance is the haversine of it. The Dart apps keep their own straight-line fallback for
the 500 case regardless.

## Platform and Utility

| Method | Path | Auth | Notes |
|---|---|---|---|
| POST | `/api/v1/sos` | Yes | Creates an SOS response payload, but it is not persisted |
| POST | `/api/v1/feedback` | Yes | Stub-like acknowledgement |
| POST | `/api/v1/devices` | Yes | Registers a device token |
| DELETE | `/api/v1/devices/:token` | Yes | Unregisters a device token |
| GET | `/api/v1/heatmap` | Yes | Stub |
| GET | `/api/v1/drivers/:id/location` | Yes | Returns current driver location |
| GET | `/api/v1/version` | No | App version metadata |

### Device body

```json
{
  "token": "device-token",
  "platform": "ios"
}
```

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
| `ride.updated` | Sent on ride create, accept, cancel, status changes, and completion |
| `driver.location` | Sent to the rider during an active ride |
| `pong` | Reply to `ping` |

## Current Behavior Notes

- `POST /api/v1/auth/social` is exposed but returns a not-yet-implemented response.
- `POST /api/v1/rides/:id/tip`, `PUT /api/v1/rides/:id/destination`, `GET /api/v1/geo/isochrone`, `GET /api/v1/places/*`, `GET /api/v1/promotions`, `POST /api/v1/promotions/apply`, and several rider/driver profile extras are stubs.
- `POST /api/v1/rides` calculates fare using the current fare service, including distance, time, and surge heuristics.
- `POST /api/v1/driver/rides/:id/accept` is the HTTP accept path; websocket `ride.accept` is the live driver channel used by dispatch.
- If dispatch finds no driver, the ride can move to `no_driver_available`.

## Recommended Rider Flow

1. Register or login.
2. Connect to `GET /ws` with the access token.
3. Update rider location if needed.
4. Request a ride with `POST /api/v1/rides`.
5. Wait for `ride.updated` and `driver.location` websocket events.
6. Track the ride with `GET /api/v1/rides/current` or `GET /api/v1/rides/:id`.
7. Rate the ride after completion.
