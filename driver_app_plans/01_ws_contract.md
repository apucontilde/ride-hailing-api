# Plan 01 — WebSocket contract + ride-state machine

> **Status: ✅ LANDED** (re-audited 2026-09-25). `core/network/ws_event.dart` maps
> every backend type (`ride.offer` with only a `ride_id`, `ride.updated`,
> `driver.location`, unknown → `other`) and nests `data` per
> `internal/websocket/hub.go:95-110`, so the send helpers use the real wire
> format. `RideStateNotifier` owns the machine: offer + 30 s expiry, single-offer
> policy, `clearOffer()`/`clearRide()`, `adoptRide()` for rides learned over
> HTTP, and a `ride.updated` **patch merge** (`core/ride/ride_update.dart` —
> the broadcast is `ride_id` + nested `pickup`/`dropoff`/`fare`, not a flat
> `Ride`; plan 04 found that out the hard way). Tests:
> `websocket_service_test.dart` + `ride_state_notifier_test.dart`.
> **Superseded:** the plan's debug banner on `ride.offer` was replaced by plan
> 03's real offer sheet, which `home_screen.dart` opens.
> **One loose end:** `lastLocation` is stored but still has no consumer, and it
> never will: the server only pushes `driver.location` to the **rider**, so the
> driver app receives nothing on that event. Plan 04 therefore routes from the
> driver's own GPS fix (see `04`'s status block).

Make the driver app a first-class `/ws` participant: consume every broadcast event,
send accept/decline/ping in the **real nested wire format**, and own the ride-state
machine in one notifier so every later plan (offers, trip, history) feeds off it.

## Facts (re-audited)

- Connection: authenticated `ws://<API_WS_BASE>/ws` with
  `?token=<access_token>`. The **shared** `WebSocketService`
  (`shared/lib/src/network/websocket_service.dart`, re-exported by
  `lib/core/network/websocket_service.dart` which also defines
  `webSocketServiceProvider` against `ApiConfig.baseUrl`) already opens it,
  replays `events` broadcasts, and auto-reconnects on error with a small
  backoff.
- **Driver SEND (nested — mandatory):** the hub decodes the action from
  `{"type","data"}` and reads `ride_id` from `incoming.Data`
  (`internal/websocket/hub.go:94-110`):
  - `{"type":"ride.accept","data":{"ride_id":"<ride_id>"}}` → dispatch
    `HandleAccept` (`internal/service/dispatch.go:127-136`) → only succeeds while
    an offer is outstanding.
  - `{"type":"ride.decline","data":{"ride_id":"<ride_id>"}}` → `HandleDecline`
    (`dispatch.go:138-145`), fire-and-forget.
  - `{"type":"ping"}` → hub replies `pong`; used for liveness.
  ⚠️ `DRIVER_APP_PLAN.md` §2.4 documents the flat form
  `{"type":"ride.accept","ride_id":...}` — **broken**. This plan enforces nested.
  (The shared `WebSocketService.acceptOffer/declineOffer` already send nested —
  keep it that way; delete any flat payload copy in comments.)
- **Driver RECEIVE** (`service/dispatch.go:114-117`, `dispatch.go:66`): every event
  is `{type, data}`.
  - `ride.offer`: `data={"ride_id":"..."}` (nothing else — never trust embedded
    ride data; fetch it). 30 s to decide (`dispatch.go:122`). Offers only reach
    drivers whose WS is live (`dispatch.go:97`).
  - `ride.updated`: `data` is the full `Ride` JSON (status `pending|accepted|
    driver_arrived|in_progress|completed|cancelled`; on `completed` the payload
    also carries `driver`, `pickup`, `dropoff`, `fare`; on `cancelled` it carries
    `cancelled_by`).
  - `driver.location`: `data={"lat":..,"lng":..,"heading":..,"speed":..}` (any
    linked driver) — drive the rider's live location on the trip map later.

## Work

1. `lib/core/network/websocket_service.dart` (driver shim over the shared
   service — see **Work** below; the shared service already provides `connect`,
   `events`, `acceptOffer`, `declineOffer`, `ping`, `dispose()`).
   - Normalize decoded events: `enum WsEventType {offer, updated, location, other}`
     + a parsed `data` map. Expose
     `Stream<WsEvent> get events` where `WsEvent{type, data}`.
2. `lib/core/network/ws_event.dart` (new, driver-app local): `WsEvent` +
   `WsEventType`.
3. `lib/core/ride/ride_state_notifier.dart` (new):
   - `Ride` model already lives in **shared** (`shared/lib/src/models/ride.dart`,
     exported as `Ride` by the barrel — `id, rider_id, status, pickup_lat/lng/address,
     dropoff_lat/lng/address, vehicle_type, base_fare, distance_fare, time_fare,
     surge_multiplier, total_fare, requested_at, accepted_at, driver_arrived_at,
     started_at, completed_at, cancelled_at` with `fromJson`). Do not re-create it.
   - `rideStateProvider = StateNotifierProvider<...>` with:
     - `currentRide` (Ride?), `offeredRideId` (String?), `offerExpiresAt`
       (DateTime?).
     - `onWsEvent(WsEvent)`: `offer` → store `offeredRideId` + 30 s deadline
       AND spawn local timeout that self-clears the offer; `updated` → replace
       `currentRide` (and clear `offeredRideId` when status != `pending`);
       `location` → store last `driver.location` for the map.
     - `acceptOffer()` → `websocket.acceptOffer(rideId)` then set `currentRide`
       to a local "accepted placeholder" so UI flips immediately; the server's
       `ride.updated` replaces it.
     - `declineOffer()` → `websocket.declineOffer(rideId)`; clear offer locally.
     - `clearRide()` after completion/cancellation acknowledgement.
- Depend on `webSocketServiceProvider` + `apiClientProvider` (both already
  defined app-local in `lib/core/auth/auth_provider.dart` and
  `lib/core/network/websocket_service.dart`; `/home` surfaces profile load via
  `driverProfileProvider`, so rely on providers, not static config).
4. Route a sample through the home screen: on `ride.offer` show a minimal debug
   banner (replaced by plan 03's dialog) — proves the stream is live end-to-end.

## Tests

- `test/core/network/websocket_service_test.dart` (against the shared service,
  via the driver shim): nested JSON sent for accept/decline/ping
  (`verify(mockSocket.add(jsonEncode({'type':'ride.accept',
  'data':{'ride_id':'r1'}})))` style); events broadcast decodes offer/updated/
  location; reconnect triggers on error.
- `test/core/ride/ride_state_notifier_test.dart`: offer sets offered id + deadline;
  local 30 s expiry clears it; `ride.updated` replaces current ride and clears
  offer; accept sends WS message and sets placeholder; decline clears offer.

## Acceptance

- WS contract is 100% nested; no flat `ride_id` payloads remain.
- Single `rideStateProvider` is the source of truth for offer + current ride.
- Analysis clean, all tests green (`melos run analyze` / `melos run test`).

## Verification

```bash
make flutter-analyze
make flutter-test
```