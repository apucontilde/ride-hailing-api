---
tag: dispatch
depends_on: ["dispatch offer path + socket retry + skip tracing (STATUS.md)"]
status: open
---

# Plan: Dispatch offer-path fixes — offers delivered and answered reliably

**Unnumbered / independent.** `depends_on` names *landed* dispatch capability (the socket
retry, skip-reason tracing and terminal-write handling in `STATUS.md` → Landed `[dispatch]`),
not an open plan.

> Coalesces two reviewed findings on the dispatch **offer path**:
> **A3** — bug #11: a DB-fresh online driver whose socket is genuinely absent is dropped
> after the ~450 ms retry (`internal/service/dispatch_observability.go:208-226`;
> `internal/websocket/hub.go:120-125` is map-presence only). The driver-side keepalive half
> already landed; the server-side half is open.
> **A4** — the HTTP decline route is mis-wired to a payment stub, so an HTTP path decline
> records nothing (`internal/router/router.go:235`).
> Both are the same product property: an offer is delivered and its answer is recorded.

---

## A3 — bug #11: a reconnecting online driver must not lose the offer

### Current state (verified)

- The offer loop calls `waitForSocket` before sending `ride.offer`
  (`internal/service/dispatch.go:206-244`).
- `waitForSocket` polls the hub `socketBackoffAttempts = 4` times with
  `socketBackoffDelay = 150 ms` between checks — a **~450 ms** total window — and on failure
  records `skipSocketNotConnected` and drops the candidate
  (`internal/service/dispatch_observability.go:187-188,208-226`).
- `Hub.IsConnected` is **map presence only** (`internal/websocket/hub.go:120-125`): it cannot
  tell a live socket from a stale entry for a half-open TCP connection, and it cannot
  distinguish "reconnecting" from "never connected".
- The search already matches DB-fresh, online drivers; the hub registers a client a moment
  after the `/ws` handshake, and a reconnect re-enters that window. The driver-side keepalive
  is landed (opt-in `heartbeatInterval` `ping()` loop, 25 s cadence):
  `shared/lib/src/network/websocket_service.dart:37,54-58,112,148-156`,
  `driver_app/lib/core/network/websocket_service.dart:17,32,45-55,78-86`. So a normal driver
  stays connected, but a reconnect gap longer than 450 ms still drops the offer.

### Fix (server-side half)

1. **Make hub presence truthful.** Track per-client liveness (`lastSeen`, refreshed on every
   inbound frame including `ping` and the `pong` reply) with a deadline, and have
   `IsConnected` return true only for a client within that deadline. A stale/half-open entry
   then stops reading as connected, and a reconnect visibly refreshes presence. Keep
   `IsConnected`'s signature (it is called from dispatch and tests).
2. **Replace the fixed 450 ms hard-skip with a bounded, re-armed wait.** A candidate that is
   DB-online but temporarily socket-absent should stay eligible for the **offer window**
   (`offerTimeout = 30 s`, `dispatch_observability.go:190`), not be permanently dropped on a
   450 ms miss. Two acceptable shapes (pick one, keep it non-blocking for other candidates):
   - re-attempt the candidate on the next widening search round instead of `continue`-ing past
     it, or
   - a short per-driver deferred retry bounded by `offerTimeout`.
   The sequential loop (`sendRequestsSequentially`, `dispatch.go:162-204`) must not sleep for
   the whole window per absent candidate.
3. **Preserve the trace contract.** Record exactly **one** terminal skip
   (`skipSocketNotConnected`) only when the driver never connects within the window; the
   per-poll retry lines stay `socket-wait` (never the `skip` verb), as today
   (`dispatch_observability.go:156-165,208-226`). If a new "deferred" state is introduced, add
   a distinct `offerSkipReason` rather than overloading free text.

### Tests

- Keep green: `TestDispatchSocketRetrySucceedsWhenDriverConnectsDuringBackoff`
  (`internal/service/dispatch_test.go:584`), `TestDispatchSkipsDriverWithNoSocketAndRetries`
  (`:527`), `TestSocketWaitRecordsOneSkipForADroppedDriver` (`:1130`),
  `TestSocketWaitLogsRetriesWithoutTheSkipVerb` (`:1099`).
- New: a driver that connects **after** the fixed backoff but within the offer window is still
  offered (re-arm); a client whose liveness deadline elapsed reads `IsConnected == false`; a
  genuinely absent driver still records exactly one `socket_not_connected` skip.

---

## A4 — the HTTP decline route must record a decline, not return a payment stub

### Current state (verified)

- `POST /api/v1/driver/rides/:id/decline` is bound to `platformHandler.StubPayment`:
  `internal/router/router.go:235`.
- `StubPayment` answers `200 {"status":"stub","message":"Payment integration pending"}`
  (`internal/handler/platform.go:628-642`) and records **no** decline — a false success for a
  driver who declined.
- The WS path **is** real: a `ride.decline` frame calls
  `DispatchService.HandleDecline(driverID, rideID)`
  (`internal/websocket/hub.go:105-111`), which signals the active offer channel
  (`internal/service/dispatch.go:257-264`); the offer loop then records
  `skipDriverDeclined` (`:232-237`).
- `HandleDecline` currently returns nothing and silently ignores "no active offer", so it
  cannot drive an HTTP status.
- The driver app declines over the WS today (`driver_app/lib/core/ride/ride_state_notifier.dart:159`),
  and documents HTTP as the dead-socket fallback (`driver_app/lib/features/rides/presentation/offer_sheet.dart:11`);
  the endpoint constant exists (`driver_app/lib/core/api/endpoints.dart:34`), so the fallback
  is currently a lie.

### Fix

1. **Add the real handler** (e.g. `RideHandler.DeclineRide`, wired at
   `internal/router/router.go:235`), mirroring the WS path. It resolves the driver from the
   JWT (the group already enforces `RequireRole("driver")`) and the ride id from the path.
2. **Give the service a result to map.** Change the decline service path to return an error
   (e.g. `DeclineOffer(driverID, rideID) error` with a sentinel `ErrNoActiveOffer`); keep the
   WS `HandleDecline` adapter as log-and-ignore. Map in the handler:
   - active offer signalled → success (`204 No Content`, or `200 {"status":"declined"}` —
     pick one and document it);
   - no active offer → `404 NOT_FOUND` (never a 2xx lie);
   - malformed/missing id → `422 VALIDATION_ERROR` (house contract);
   - repository/internal failure → `500 INTERNAL` via `respondRepo`.
3. **No stub body on the route.** The response must never contain `"status":"stub"`.
4. **Mocks in lockstep** (`tests/testutil/`) so `make test` runs DB-free.

### Tests

- Contract test (`tests/`): authenticated driver `POST …/decline` on an **active** offer
  returns the documented success status (not the stub) and the dispatch trace records
  `driver_declined`; a decline with **no** active offer returns the documented non-2xx;
  malformed id is 422.
- Assert the body does not contain `"Payment integration pending"`.
- WS-path regression: `ride.decline` still records `driver_declined` unchanged.

---

## Invariants

- Success paths / status codes for valid existing requests never change (except the
  stub→real decline route, which is the fix).
- A failed write never answers success; a cause is logged (`c.Error`) when a message is
  generalised; `err.Error()` never appears in a response body.
- `near_pickup`/push must never announce a status the database does not hold.
- Mocks move in lockstep with repositories.
- The rider app draws a straight line on every error status for routes; dispatch status
  changes must keep answering the documented 2xx/4xx/5xx contract.

## Verification

```bash
make test                       # unit tests, no DB (must stay green)
make lint                       # golangci-lint v2, 0 issues
gofmt -w <files> && go vet ./...
```

## Open inputs

| Unknown | Resolve with |
| --- | --- |
| Success status for decline: `204` vs `200 {"status":"declined"}` | Match the accept route's convention (`AcceptRide`) and the driver app's fallback parser |
| Whether re-arm is per-search-round or a deferred queue | Choose the shape that does not head-of-line block `sendRequestsSequentially`; record the choice in code |
| Liveness deadline value | Must be > the driver heartbeat cadence (25 s) and < the 30 s offer timeout, or tied to the heartbeat |
