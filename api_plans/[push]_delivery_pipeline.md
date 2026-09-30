---
tag: push
depends_on: []
status: open
---

# Push delivery pipeline (device tokens + FCM/APNs + backgrounded notifications)

Net-new feature. Arrival notification is "already" delivered only over an open
WebSocket; there is no backgrounded push pipeline, and the device token endpoints
and table are stubs. Plan the full delivery pipeline.

## Current state (all cited from code)

- Live-notify over WS is real: after a status transition the service broadcasts
  `ride.updated` to the rider — `internal/service/ride.go:193` (`s.hub.SendToUser(ride.RiderID, msg)`),
  which carries `driver_arrived` (and the fare payload on completion).
- But `POST /driver/rides/:id/notify-arrival` is a **no-op stub** —
  `internal/handler/platform.go:466-477` (`ArrivalNotification`) returns
  `{"message":"rider notified of arrival"}` without sending anything.
- Device register/unregister are **stubs** — `internal/handler/platform.go:106-128`
  (`DeviceRegister` returns `201 "device registered"`; `DeviceUnregister` returns
  `204` with no DB write).
- The `device_tokens` table exists in schema but is **never written** —
  `internal/database/migrations/007_create_misc.up.sql:36` (the `CREATE TABLE
  device_tokens` block: `id`, `user_id`, `token`, `platform` enum, …).

## Scope

1. **Device-token persistence** — implement register/unregister to actually write
   `device_tokens` (respecting the append-only migration rule; the table already
   exists so this is repo plumbing, not schema), with one active token per
   user+platform and revoke-on-unregister.
2. **Delivery provider** — a push abstraction (FCM for Android, APNs for iOS, web
   as a fallback/no-op) behind an interface, so tests use a mock in lockstep with
   the production client.
3. **Backgrounded notify-arrival + ride updates** — wire `ArrivalNotification` (and
   the completion/status broadcast) to also fire a background push when the rider's
   WebSocket is *not* connected, keeping the existing WS path for the connected
   case. Failure semantics: a push that cannot be delivered is ancillary/best-effort
   — log it, never fail the authoritative action.

## Cross-app dependency

- Both apps' safety plans reference backgrounded push (rider: arrival/safety
  notifications; driver: proximity updates). The delivery pipeline here is the API
  contract both `rider-planner` and `driver-planner` consume; this plan stops at
  the server side.

## Invariants carried in

- Ancillary rows (`device_tokens`) are best-effort: never change a response or fail
  a request over a token write.
- Success paths/status codes for valid requests never change.
- A failed write never answers success; a cause is logged.