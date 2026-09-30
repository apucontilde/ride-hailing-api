---
tag: dispatch
depends_on: ["api_plans/[dispatch]_reliability_and_no_driver_false_negative.md"]
status: open
---

# Driver half: keep-alive + offer reliability

> **Driver (client) half of the dispatch false-negative fix.** The API-side selection/liveness
> work is owned by `api_plans/[dispatch]_reliability_and_no_driver_false_negative.md` (head,
> unnumbered); that head explicitly names "driver-side keep-alive `ping()` (and re-publish on
> reconnect)" as this plan's contract. Adopt that contract here — do **not** redesign the
> server-side selection logic.

## Read first (repo-relative)

- `shared/lib/src/network/websocket_service.dart` (`ping()` at 136, `isConnected` at 39)
- `driver_app/lib/core/network/websocket_service.dart` (typed facade; `ping()` at 40)
- `driver_app/lib/core/ride/ride_state_notifier.dart` (offer/updated state machine)
- `internal/service/dispatch.go` (`offerRideToDriver` gate at 101-105)

## Facts (verified)

- **No keep-alive:** `ping()` exists as a send helper (`shared/.../websocket_service.dart:136`,
  wrapped by `driver_app/.../websocket_service.dart:40`) but is **never called** by production
  code — only a unit test (`driver_app/test/core/network/websocket_service_test.dart:74`). No
  `Timer.periodic` heartbeat exists anywhere in the driver app (the only periodic timer is the
  offer countdown, `offer_sheet.dart:74`).
- **`isConnected` is not liveness:** `bool get isConnected => _channel != null`
  (`shared/.../websocket_service.dart:39`). An idle socket that dies on NAT/intermediary timeouts
  still reads "connected" — the connect-disconnect bookkeeping never learns the socket is dead
  until a read/write actually fails.
- **Server consequence:** dispatch skips a driver whose socket isn't in the hub map —
  `internal/service/dispatch.go:101-105` (`offerRideToDriver` returns false when
  `!s.hub.IsConnected(driverID)`), where the hub's "connected" is map presence
  (`internal/websocket/hub.go:120-125`). A dead-but-"connected" socket therefore leaks a
  DB-fresh, genuinely online driver out of the offer loop (false negative), exactly Gap B of the
  api head.

## Work

1. **Heartbeat:** send `ping()` on a fixed interval while online (e.g. a `Timer.periodic` owned
   by the driver facade/svc, started when the socket connects and cancelled on disconnect). Stop
   the timer when the driver goes offline or the service disposes.
2. **Re-publish on reconnect:** after a reconnect, re-issue the driver's last known position
   (`publishLastPosition`) and re-send `ping` so the driver is immediately re-eligible — matches
   the api head's "re-publish on reconnect" contract (see also
   `driver_app/lib/core/location/location_service.dart` and the api head's Gap A). Confirm the
   existing reconnect path (`websocket_service.dart:95-101`) hooks into this.
3. **Liveness honesty (optional, cheap):** if feasible without new server endpoints, reflect
   real socket health rather than bare `_channel != null` — otherwise document `isConnected` as
   "open, not alive" in the facade and let the heartbeat be the real liveness signal.
4. Tests: extend `driver_app/test/core/network/websocket_service_test.dart` to assert the
   heartbeat fires on an interval while connected and stops on disconnect/dispose.

## Out of scope

- Server selection/liveness (`MarkStaleDriversOffline` cron, offer-skip reconciliation, logging
  on `no_driver_available`) — all in the api head. Note only.
- **Known bug #12 (second ride dropped while `currentRide` is stale)** — a *different* dispatch
  defect, traced to the `ride_state_notifier.dart:92` guard plus a user-only `clearRide()`
  (`trip_screen.dart:109-113`), recorded in `driver_app_plans/STATUS.md`. It is *not* fixed by this
  plan's heartbeat/re-publish work despite the plan's "offer reliability" title; it is now owned by
  `driver_app_plans/[ws]_late_update_and_state_cleanup.md`.

## Acceptance

- An idle driver socket no longer silently dies on NAT/intermediary timeouts: the driver keeps
  it alive with `ping`, so dispatch's `isConnected` gate sees a live socket.
- Reconnect re-publishes position + heartbeat, so a freshly-reconnected driver is immediately
  offerable.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```