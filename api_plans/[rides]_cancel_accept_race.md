---
tag: rides
depends_on: []
status: open
---

# [rides] Cancel / accept race: atomic transitions and one accept funnel

> **Owner:** `api-planner`. This file is the **canonical cross-domain contract** for ride
> cancellation and driver acceptance. The driver-app consumer plan must adopt §2 and §4 verbatim
> (names, status codes, frame shapes). Do not rename them later without a cross-domain note.
>
> **Prerequisite capability (already landed, not open plans):** the `[rides]` state machine
> (`internal/service/ride.go:119`), the `[dispatch]` offer path (`internal/service/dispatch.go:317`),
> the `[arrival]` proximity geofence (`internal/service/arrival.go:82`), and the `[errors]` HTTP
> taxonomy (`internal/handler/respond.go:19`). This plan is an independent chain head: its
> prerequisites are landed code, so it is **unnumbered**.

## Incident (2026-10-19)

Rider cancelled ride `83ccb6f7-…` at 15:45:24. The API answered `200` with
`ride.status="cancelled"` but `driver_id=null`, `accepted_at=null`, `cancelled_at=null`, and
`updated_at == created_at`. The driver then POSTed `/api/v1/driver/rides/<id>/cancel` twice
(15:45:26, 15:45:36); both answered `400 {"error":{"code":"BAD_REQUEST","message":"ride cannot be
cancelled"}}`. At 15:45:35 the server logged `failed to handle ride accept: no active offer for
ride <id>`. The driver app stayed on the cancelled ride because `CancelRide` only broadcasts
`ride.updated cancelled` to `ride.DriverID`, which was `NULL` (the driver only held an offer), and
the driver-app WS accept path optimistically claims the offer without a server ack.

**Root causes, all confirmed in the tree:**

1. `CancelRide` does a read, a check, then an **unconditional** `UPDATE`; it never re-reads, so the
   response carries the pre-write struct (`cancelled_at` NULL, stale `updated_at`).
   `internal/service/ride.go:383-408`; `internal/repository/ride_repo.go:299-329`.
2. There is no expected-status guard on the write, so any concurrent transition can be clobbered.
   `internal/service/ride.go:395,445`; `internal/service/dispatch.go:172`.
3. Cancellation is authorized by **role only**, and every failure is mapped to the same `400`.
   `internal/handler/ride.go:553-561`.
4. The parked offer is not withdrawn on cancel, and the offered driver is not notified.
   `internal/service/dispatch.go:317-355`; `internal/service/ride.go:419-427`.
5. `HandleAccept` ignores the driver ID, returns success without an assignment result, and the HTTP
   accept path bypasses the offer channel entirely. `internal/service/dispatch.go:364-372,400`;
   `internal/handler/ride.go:681-694`. **Security/correctness consequence:** `HandleAccept` never
   compares `offer.driverID` to the caller, so **any authenticated driver can send `ride.accept` for
   a parked ride and force the offered candidate to be assigned without that candidate's consent**
   (`internal/service/dispatch.go:364-372`; the accepted signal is consumed by the loop at
   `:296-305`, which then calls the assignment write for the *offered* driver). The fix is the
   driver match in §4.1 step 3; a `NOT_OFFERED` test must assert the offered driver is **not**
   assigned and the offer is left untouched.

**`no_driver_available` live production defect — fixed by the landed `[dispatch]` hotfix (not by
this plan).** The `[dispatch]` SQL hotfix has landed and was adversarially
confirmed FIXED: `UpdateRideStatus`'s timestamp-column switch and query builder now emit
`UPDATE rides SET status=$1, updated_at=NOW() WHERE id=$2` for `no_driver_available` (no dangling
`=$2`), `finishWithoutDriver` reaches its push on success, and a failed write still pushes nothing
(`internal/repository/ride_repo.go:305-355`; tests `internal/repository/ride_repo_test.go:16`,
`internal/repository/ride_status_integration_test.go:20`,
`internal/service/dispatch_test.go:497`). The replacement write in §1 must **preserve** that
no-timestamp-column form when it supersedes the method; the DB-backed
`pending → no_driver_available` test in §5.4 stays a **required gate** for the `UpdateRideStatusFrom`
form (not optional).

---

## 1. Atomic status transitions (the core race fix)

### 1.1 Repository contract (canonical)

Replace the unconditional `UpdateRideStatus` in `RideRepository`
(`internal/repository/ride_repo.go:25`) with exactly this method:

```go
// UpdateRideStatusFrom performs one conditional status transition. It returns
// updated=false with a nil error when no row matched expectedFrom (a lost
// race, or the ride is already in a different state). A non-nil error is a
// real repository failure and must become a 5xx.
UpdateRideStatusFrom(rideID string, expectedFrom []string, status string, timestamp *time.Time) (updated bool, err error)
```

Semantics:

- SQL shape:
  `UPDATE rides SET status=$1, <ts_col>=$2, updated_at=NOW() WHERE id=$3 AND status = ANY($4)`
  with `pq.Array(expectedFrom)` (the `lib/pq` import already exists at
  `internal/repository/ride_repo.go:11`). Use `Exec` + `RowsAffected()`; return `(rows == 1, nil)`.
- `status` → timestamp column mapping is a **fixed** map (no SQL interpolation):
  `accepted→accepted_at`, `driver_arrived→driver_arrived_at`, `in_progress→started_at`,
  `completed→completed_at`, `cancelled→cancelled_at`. For `no_driver_available` (and any future
  status without a timestamp column) the SET clause is only `status=$1, updated_at=NOW()`.
  **Preserve this form:** the landed `[dispatch]` hotfix already fixed the old `no_driver_available`
  syntax bug in the helper (`internal/repository/ride_repo.go:305-355`); do not regress it when
  replacing the method.
- `timestamp == nil` means `time.Now()` for statuses that have a timestamp column.
- `expectedFrom` is never empty; an empty slice must be a programming error (return a non-nil
  error), not an accidental unconditional update.
- Remove the old `UpdateRideStatus` method from the interface and all production call sites so no
  unconditional write path remains.

**Decision (locking semantics):** a `0 rows` result is **not** an error; it is a legitimate
lost-race outcome. Keeping it as `(false, nil)` lets the service distinguish "someone else won"
(idempotent cancel, arrival log-and-swallow) from a database outage (5xx). The alternative
`(false, ErrConflict)` is rejected because it conflates the two.

### 1.2 Production call sites (all go through it)

| Site | Current write | Required behaviour on `updated == false` |
| --- | --- | --- |
| `RideService.CancelRide` `internal/service/ride.go:395` | `UpdateRideStatus(id,"cancelled")` | Re-read once. Fresh `cancelled` → idempotent success (§2.2). Otherwise → `ErrCannotCancel` (409). |
| `RideService.AdvanceStatus` `internal/service/ride.go:445` | `UpdateRideStatus(id,newStatus)` | `expectedFrom = []string{ride.Status}`. On `false`, return `ErrTransitionConflict` (409) **before** any event, completion fare/actuals/earnings, broadcast, or push. `[arrival]` logs and swallows it. |
| `DispatchService.finishWithoutDriver` `internal/service/dispatch.go:172` | `UpdateRideStatus(id,"no_driver_available")` | `expectedFrom = []string{"pending"}`. On `false`, record `not_pending` on the trace, log, and **do not push**. On error, keep the existing `noteTerminalError`, log, and do not push. |
| `sendRequestsSequentially` post-loop check `internal/service/dispatch.go:280` | re-read + later write | Keep the re-read as an early exit, but the conditional write is the authority; there is no lost-update window. |

`AdvanceStatus` must run the completion block (`SetRideActuals`, `FinalizeRideFare`,
`CreditRideEarning`, fare DTO) **only after** `updated == true`
(`internal/service/ride.go:465-595`). On a lost race the request is a 409 and the ride row is
untouched.

Add `ErrTransitionConflict` (e.g. `errors.New("ride status changed concurrently")`) and map it to
`409 CONFLICT` in `RideHandler.AdvanceStatus` (`internal/handler/ride.go:602-614`; today only
`ErrInvalidTransition` is special-cased to 400 and everything else goes through `respondRepo`,
which would turn this sentinel into a 500). `[arrival]` never reaches the handler, but the manual
`PUT /:id/status` must not report a lost race as an outage.

### 1.3 `[arrival]` invariant

`EvaluateArrival` calls the shared `AdvanceStatus`
(`internal/service/arrival.go:82`). A lost-race `accepted→driver_arrived` (because a cancel or a
manual transition committed first) must:

- return a non-nil conflict error from `AdvanceStatus`,
- write **no** `ride_events` row,
- broadcast **no** `ride.updated driver_arrived`,
- send **no** `driver_arrived` push,
- be logged and swallowed by `EvaluateArrival` exactly as today
  (`internal/service/arrival.go:83-86`).

This preserves the `[arrival]` invariant in `api_plans/STATUS.md:723-729`: the geofence never
clobbers a terminal status and never fails the location update.

### 1.4 Mock and test-double obligations (lockstep)

- `tests/testutil/mock_repos.go:627` — replace `MockRideRepo.UpdateRideStatus` with
  `UpdateRideStatusFrom`. It must return `(false, nil)` when `r.Status` is not in `expectedFrom`,
  `(true, nil)` on a match, and propagate a configured error. It must apply the same fixed
  timestamp-column map and `UpdatedAt = time.Now()`.
- **Test-double freshness (model the real copy-on-read/stale-struct behaviour):**
  `MockRideRepo.FindByID` must keep returning a **copy** of the stored ride
  (`tests/testutil/mock_repos.go:391-399`), and `UpdateRideStatusFrom` must mutate the **stored**
  struct (`:627-655`), never the caller's/pre-write struct. Otherwise
  `TestCancelReturnsFreshTimestamps` would pass against the mutated pre-write value and would not
  prove the service re-read. The test must assert a value that only the post-write re-read can
  produce (e.g. the mock sets `UpdatedAt` in the stored row and `FindByID` returns a distinct copy
  with the new timestamp).
- `tests/testutil/mock_repos.go:730` — `MockRideRepo.AssignDriver` already models the DB guard
  (`r.Status != "pending"` → `ErrConflict`). Keep it and add a test that it is the only assignment
  write the accept funnel uses.
- Stub repos that embed `RideRepository` must gain the method or they will not compile:
  `internal/service/ride_completion_fare_test.go:30`, `internal/service/destination_test.go:44`,
  `internal/service/arrival_test.go:66`, `internal/service/dispatch_test.go:142`.
- `tests/multi_stop_test.go:318` calls `ts.RideRepo.UpdateRideStatus(...)` to force a completed
  ride; switch it to `UpdateRideStatusFrom(id, []string{<current>}, "completed", nil)`.
- `fakeRideRepo` in `internal/service/dispatch_test.go` must model `expectedFrom` and expose
  `statusUpdates` so the no-clobber tests can assert the exact transition.

### Acceptance criteria

- [ ] `UpdateRideStatusFrom` returns `false, nil` on a stale expected status and leaves the row
      unchanged; returns a non-nil error on a real DB failure.
- [ ] `no_driver_available` succeeds on a real database (the empty-column SQL is gone — the landed
      `[dispatch]` hotfix fixed it; `UpdateRideStatusFrom` must preserve the no-timestamp-column
      form); the DB-backed `pending → no_driver_available` test (§5.4) is a **required gate** for
      the CAS form.
- [ ] A normal "nobody found" ride reaches terminal `no_driver_available` and the rider receives
      the update, instead of staying `pending` forever.
- [ ] No production code calls an unconditional ride-status write.
- [ ] A lost-race `AdvanceStatus` produces no event, no broadcast, no push, and no fare/earnings
      side effect.
- [ ] The arrival geofence still never fails the location update and logs the swallowed conflict.

---

## 2. Cancel contract (canonical)

### 2.1 Signature and authorization

Change the service signature to:

```go
func (s *RideService) CancelRide(rideID, actor, callerID string) (*model.Ride, error)
```

- `actor` is the JWT role (`"rider"` or `"driver"`) and is what `cancelled_by` / `ride_events.actor`
  use.
- `callerID` is the JWT `user_id`.
- Handler changes (`internal/handler/ride.go:553-561`): validate the UUID with the existing
  `uuidRE` (`internal/handler/ride.go:471`) → `422 VALIDATION_ERROR "invalid ride id"`; read both
  `role` and `user_id`; call the new signature.
- Route gates: add `middleware.RequireRole("rider")` to `POST /api/v1/rides/:id/cancel`
  (`internal/router/router.go:276`). The driver-role gate is the group middleware on
  `driverRides.Use(authMw, middleware.RequireRole("driver"), …)` at
  `internal/router/router.go:247` (not the `:250` line, which is `GET /queue`, nor `:256`, which is
  the driver cancel route).
- Ownership (after `FindByID`):
  - `actor == "rider"` and `ride.RiderID != callerID` → `ErrNotRideRider`
    (`internal/service/ride.go:147`).
  - `actor == "driver"` and (`ride.DriverID == nil || *ride.DriverID != callerID`) →
    `ErrNotRideDriver` (new additive sentinel; same 404 mapping). A pending ride has no driver, so
    a driver cannot cancel it.
  - Any other role → the same 404 path.
  - **Both** mismatch sentinels and `repository.ErrNotFound` map to
    `404 NOT_FOUND {"error":{"code":"NOT_FOUND","message":"ride not found"}}`; never 403, so a
    caller cannot probe for the existence of another user's ride. This mirrors
    `ChangeDestination` (`internal/service/ride.go:646`; `internal/handler/ride.go:366`).

### 2.2 Status rules and idempotency

Cancellable set (both roles): `pending`, `accepted`, `driver_arrived`
(`validTransitions` already allows `pending|accepted|driver_arrived → cancelled`,
`internal/service/ride.go:119-126`).

- Perform **one** conditional write with
  `expectedFrom = []string{"pending","accepted","driver_arrived"}`. This is deliberate: if a
  concurrent `AssignDriver` commits first, the ride is `accepted`, which is still in the set, so the
  rider's cancel still wins (decision §6a). If the cancel commits first, `AssignDriver`'s
  `WHERE status='pending'` (`internal/repository/ride_repo.go:414`) fails and no assignment happens.
- Already `cancelled` (authorized): return `200` with the **current** ride. Do **not** write a
  second `ride_events` row and do **not** re-broadcast/re-push to participants already notified.
  Still call the idempotent offer withdrawal (§3) so a phantom parked offer, if any, is closed; if
  it finds one, that offered driver is a **new** recipient and still gets `ride.offer_closed` plus
  the terminal `ride.updated cancelled` (not a duplicate for them), while the rider/assigned driver
  are not re-notified.
- `in_progress` / `completed` / `no_driver_available`: return the new typed
  `ErrCannotCancel` → `409 CONFLICT "ride can no longer be cancelled"` (decision §6c). This replaces
  the blanket `400`.
- `updated == false` on the first write: re-read once. If the fresh status is `cancelled`, return
  the idempotent `200`; otherwise return `ErrCannotCancel` → `409`. A real repo error is `500
  INTERNAL "failed to cancel ride"`.
- Only after `updated == true`: write the ancillary `ride_events` row (`FromStatus` is the status
  observed on the read; a race between the read and the write can make this best-effort field
  approximate — the authoritative row is correct), withdraw the offer, then fan out (§2.3, §4.4).

**Fresh response (fixes the incident):** after the write, re-read with `FindByID` and return that
ride. `cancelled_at` and `updated_at` must be the committed values, never the pre-write struct
(`internal/service/ride.go:408` currently mutates only `Status`).

Handler status map for cancel:

| Outcome | HTTP |
| --- | --- |
| success / authorized repeat cancel | `200` `{"ride":<fresh ride>}` |
| malformed `:id` | `422 VALIDATION_ERROR "invalid ride id"` |
| ride missing or not the caller's | `404 NOT_FOUND "ride not found"` |
| `in_progress`/`completed`/`no_driver_available` | `409 CONFLICT "ride can no longer be cancelled"` |
| repo/write failure | `500 INTERNAL "failed to cancel ride"` |

Update the swagger annotations at `internal/handler/ride.go:544-552` (currently only `400`) and
document both routes.

### Acceptance criteria

- [ ] A rider can cancel only their own ride; a driver can cancel only the ride assigned to them;
      every mismatch is 404 with the same body as a missing ride.
- [ ] `cancelled_at` is non-NULL and `updated_at` is the commit time in the `200` body.
- [ ] A repeat cancel of an already-cancelled ride is `200`, writes no second event, and does not
      duplicate the participant push.
- [ ] `in_progress`/`completed` cancel is `409`, never the old blanket `400`.
- [ ] Malformed IDs are `422`, never a Postgres cast `500`.
- [ ] An outage is `5xx`, never a `4xx`.

---

## 3. Withdraw the outstanding offer on rider cancel

Today the parked `offerChannels[rideID]` stays alive up to `offerTimeout = 30s`
(`internal/service/dispatch.go:330-351`; `internal/service/dispatch_observability.go:216`) and the
offered driver is never told. The server must stop the loop promptly and notify that driver.

### 3.1 Seam (no import cycle, construction order)

`RideService` is built at `internal/router/router.go:161`; `DispatchService` at `:172`. The setter
must therefore be separate from the constructors. Both types live in package `service`, so a local
interface avoids any import cycle:

```go
// in internal/service/ride.go
type OfferWithdrawer interface {
    // WithdrawOffer closes the parked offer for rideID (if any), sends the
    // offered driver a ride.offer_closed frame, wakes the dispatch loop, and
    // returns that driver's ID ("" when no offer was parked).
    WithdrawOffer(rideID, reason string) (offeredDriverID string)
}

func (s *RideService) SetOfferWithdrawer(w OfferWithdrawer)
```

Wire it after the dispatch service is built:
`internal/router/router.go:173` → `rideService.SetOfferWithdrawer(dispatchService)` (alongside the
existing `wsHub.SetDispatchHandler(dispatchService)`). A nil withdrawer is the documented no-op
for legacy/db-less harnesses.

### 3.2 `DispatchService.WithdrawOffer`

- Lock `offerChannelsMu`; look up by ride ID; if absent, return `""`.
- Verify the entry is still the same offer generation (see §4.1 token), delete it, unlock.
- Send the offered driver
  `{"type":"ride.offer_closed","data":{"ride_id":"<uuid>","reason":"<reason>"}}`.
- Send `offerAnswer{accepted:false, err:ErrOfferWithdrawn}` on the parked answer channel so
  `offerRideToDriver` returns **immediately** (not after 30 s). `sendRequestsSequentially` must
  treat `offerWithdrawn` as a whole-loop stop and return; the post-loop re-read then records
  `not_pending`/terminal state.
- Reasons emitted here: `"cancelled"` from rider cancel. Reserve `"expired"`, `"declined"`,
  `"accepted_elsewhere"`, `"withdrawn"` for the other server-side stop points (§4.3).

### 3.3 Cancel ordering and the lost-race fallback

`CancelRide` calls `WithdrawOffer(rideID, "cancelled")` **after** the conditional write commits
and extracts the offered driver ID. It then sends `ride.updated cancelled` to the rider, to
`*fresh.DriverID` when assigned, and to the offered driver ID when it differs (§4.4).

Race coverage:

- Cancel writes first, accept funnel has already claimed/deleted the offer: `WithdrawOffer` finds
  nothing, but `acceptRide`'s `AssignDriver` fails (`WHERE status='pending'`). The funnel must
  send `ride.accept_failed` with `RIDE_NOT_PENDING` **and** re-read the ride and send
  `ride.updated` with its current status (i.e. `cancelled`) to that driver. The offered driver
  therefore still reaches a terminal state.
- Accept commits first: cancel's `accepted` is in `expectedFrom`, so it commits; `fresh.DriverID`
  is set and receives `ride.updated cancelled`; `WithdrawOffer` finds no channel (the funnel
  deleted it), which is fine.

### 3.4 Re-read before every `ride.offer` (loop must stop on a non-pending ride)

Withdrawal (§3.2) only wakes a loop that is *already parked* on an offer. The HTTP accept/WS accept
path and rider cancel can also commit **between** offers — e.g. the accept claims the offer and
returns while `sendRequestsSequentially` is moving to the next candidate
(`internal/service/dispatch.go:208-225`), or a cancel commits during the re-arm rounds (`:231-270`).
Without a fresh check the loop then sends `ride.offer` for an already-accepted/cancelled ride to a
later candidate.

Requirement: **before sending each `ride.offer` (the first round and every re-arm round), the loop
re-reads the ride and stops if its status is no longer `pending`**, recording the same
`not_pending`/terminal outcome the post-loop check records (`internal/service/dispatch.go:275-289`),
and closes the trace (`end`). This is **in addition to** offer withdrawal: withdrawal stops a parked
wait, the re-read stops the next send.

The re-read is **per candidate**, not once per round. Rationale: each candidate can wait up to
`offerTimeout` (30 s) and each re-arm round is a separate wall-clock window, so a check made once at
the top of a round is stale by the time the next candidate is offered; the check is a small indexed
primary-key read and the assignment security (the conditional `AssignDriver` + conditional status
write) remains the authority — the re-read only prevents misleading offers, it does not replace the
CAS.

Acceptance criterion: **no `ride.offer` is sent to a later candidate after an accept or cancel
commits** (assert with an accept/cancel that commits between candidates, not by sleeping for the
timeout).

### Acceptance criteria

- [ ] A rider cancel while an offer is parked stops the dispatch loop in well under 30 s (assert
      via a channel/`await` in tests, never by sleeping 30 s).
- [ ] The offered driver receives `ride.offer_closed` with `reason:"cancelled"` and a terminal
      `ride.updated cancelled` (even when `ride.DriverID` is NULL).
- [ ] No assignment can commit after the cancel (`AssignDriver` guard + conditional status write).
- [ ] If the accept write loses the race, the accepting driver gets `ride.accept_failed` and a
      terminal `ride.updated`; the server never answers `200 "ride accepted"`.
- [ ] No `ride.offer` is sent to a later candidate after an accept or cancel commits (§3.4
      per-candidate re-read).

---

## 4. Canonical accept funnel and wire contract (verbatim)

### 4.1 One funnel

`DispatchService.HandleAccept(driverID, rideID string) error` is the **only** accept entry point,
used by both the WS hub and HTTP:

- WS: `internal/websocket/hub.go:185-191` already calls `HandleAccept`; keep the interface
  (`internal/websocket/hub.go:36-39`) and send the failure frame from the hub.
- HTTP: replace `h.dispatchService.AcceptRide(...)` at `internal/handler/ride.go:685` with
  `h.dispatchService.HandleAccept(driverID, id)`.
- Make the write `acceptRide(rideID, driverID string) error` unexported (rename from `AcceptRide`,
  `internal/service/dispatch.go:400`); only `HandleAccept` calls it. `acceptRide` keeps the
  `FindByID` non-pending check, the conditional `AssignDriver`, the accepted event, and the
  `ride.updated accepted` broadcast (`internal/service/dispatch.go:400-481`).

Funnel algorithm:

1. Validate the ride ID at the HTTP handler (`uuidRE`, `internal/handler/ride.go:471`) →
   `422 VALIDATION_ERROR "invalid ride id"`.
2. Lock; look up `offerChannels[rideID]`. Missing → `ErrNoActiveOffer` (OFFER_EXPIRED / 404).
3. If `offer.driverID != driverID` → `ErrNotOffered` (NOT_OFFERED / 404). Do **not** touch the
   other driver's offer, and do **not** assign. This mirrors `DeclineOffer`
   (`internal/service/dispatch.go:389-396`) and closes the force-assign hole: today any authenticated
   driver can accept a parked ride and the loop assigns the *offered* driver
   (`internal/service/dispatch.go:364-372,296-305`), without that driver's consent.
4. Claim the offer under the lock (delete it, or mark it with the token checked in §3.2) so it
   cannot be accepted twice. Unlock.
5. Call `acceptRide`. The authoritative write result is the outcome.
6. Send `offerAnswer{accepted: err == nil, err: err}` on the parked channel so the loop stops
   immediately. **The loop must not perform a second assignment.** Today the loop reacts to
   `offerAccepted` by calling `acceptOfferedRide` → `AcceptRide`
   (`internal/service/dispatch.go:208-225,296-305`); with the funnel moved into `HandleAccept`
   that would attempt the assignment twice (once in `HandleAccept`, once in the loop) and would log
   a false `accept_failed` on the second attempt after the first succeeded. Refactor explicitly:
   **remove/replace the `acceptOfferedRide` call**; the loop only records the trace outcome
   (`accepted` / `accept_failed` / `withdrawn`) from the received `offerAnswer` and stops (or
   continues on a decline/timeout exactly as today). `HandleAccept` is the **only** caller of the
   unexported `acceptRide`; no loop branch calls it.
   **Timeout-boundary rule (details in §4.1.1):** when the 30 s timer and this answer are both
   ready, the timeout branch must observe the claimed generation and adopt this answer's outcome —
   a committed accept must never be reported as `expired`.
7. Return `err` to the caller. On a non-pending failure, re-read and send the accepting driver a
   terminal `ride.updated` for the current status (covers the cancel race in §3.3).

The WS hub must call `HandleAccept` in a goroutine (the authoritative write includes the ETA route
lookup at `internal/service/dispatch.go:450-456`, which must not block the read loop) and send the
failure frame from that goroutine. `Client.SendJSON` is mutex-guarded
(`internal/websocket/hub.go:68-71`), so this is safe.

Change the parked channel from `chan bool` to `chan offerAnswer`:

```go
type activeOffer struct {
    driverID string
    token    uint64           // guards delete/replace of a re-offered ride
    ch       chan offerAnswer // buffered 1, so a late accept/withdraw cannot block
}
type offerAnswer struct {
    accepted bool
    err      error
}
```

`offerChannels` is keyed by ride ID only today (`internal/service/dispatch.go:330`), so a re-offer
for the same ride overwrites the entry and the defer deletes unconditionally (`:335`). The token
must make deletion/claim conditional on the entry still being the one the caller owns. The channel
stays buffered (currently `make(chan bool, 1)`, `internal/service/dispatch.go:327`); a late answer
after the loop timed out must not block the HTTP handler or the WS goroutine.

#### 4.1.1 The `expired` frame is generation-claim-gated (timeout vs accept)

`time.After(offerTimeout)` and the buffered `offer.ch` can be ready at the same instant, and Go
chooses among ready `select` cases pseudo-randomly. The current timeout branch
(`internal/service/dispatch.go:430-434`, committed `a39129a`; §4.1.1 not yet implemented) records `skipOfferTimeout` and calls
`sendOfferClosed(driverID, rideID, "expired")` unconditionally, so an accept that already committed
can still produce a false `ride.offer_closed` `reason:"expired"` afterwards. The timeout branch must
distinguish **no answer** from **the answer arrived but `select` chose the timer**:

1. **Let an already-arrived answer win.** Non-blocking `select` on `offer.ch` first; if it yields an
   `offerAnswer`, process it through the same outcome switch as the answer branch (`offerAccepted`,
   `offerAcceptFailed`, `offerDeclined`, `offerWithdrawn`) and return it without recording a timeout
   skip or sending a frame.
2. **Otherwise try to claim this generation under `offerChannelsMu`.** Delete the entry only when
   `offerChannels[rideID].token == token` — the identical conditional claim `HandleAccept` step 4 and
   `WithdrawOffer` (§3.2) use. Claim success means the offer is genuinely still actionable and
   unanswered: record `skipOfferTimeout`, send `ride.offer_closed` `reason:"expired"`, return
   `offerTimedOut`.
3. **If the claim fails (entry absent), the generation was already claimed — block for that
   claimer's answer.** Do **not** record `skipOfferTimeout` and do **not** send any
   `ride.offer_closed` from the timeout branch. The entry can be gone **before** the answer exists:
   `HandleAccept` deletes the offer under the mutex **before** calling `acceptRide` (which includes
   the ETA route lookup) and sends `offerAnswer` only **after** `acceptRide` returns, so at this
   instant a non-blocking receive can legitimately find nothing. Perform a **BLOCKING receive** on
   `offer.ch` (no timeout) and return that `offerAnswer` outcome. This is safe because every claimer
   is required to send exactly one answer — `HandleAccept` step 6 after the authoritative write, or
   `WithdrawOffer` with `ErrOfferWithdrawn` — so the receive cannot wait forever; the channel being
   buffered 1 only guarantees the sender never blocks, it does **not** mean the answer is already in
   the buffer. Consequently the loop may wait for the claimant's accept/ETA work to finish, which is
   correct: returning `offerTimedOut` or sending `expired` while an accept is committing is exactly
   the bug being fixed. Do **not** re-check with a non-blocking receive after step 1 already yielded
   nothing; block for the guaranteed claimant answer. If the entry is present under a **different**
   token, a replacement generation owns it (not a claimer): return `offerTimedOut` without a frame
   and leave that generation untouched.

**Canonical mechanism: (a) the parked-generation claim, not (b) a status re-read.** The parked
`activeOffer` token is the server's linearizable answer to "may this generation still be closed?".
`HandleAccept` claims (deletes) under the same lock **before** `acceptRide` commits, and every claim
is followed by exactly one answer. Therefore either the timeout claims first — and no accept can
commit afterwards (`HandleAccept` then finds no offer and answers `OFFER_EXPIRED`) — or the accept
claims first, and the timeout observes that claim and must adopt the accept outcome. A status re-read
is **not linearizable** with `AssignDriver`: it can read `pending` just before the assignment commits
and still emit `expired` after the commit, so it would not close this race; it also puts a database
round-trip in a frame-timing decision. The claim is the same mechanism §3.2 already uses, so there is
one ownership rule for delete/replace/close, not two.

**Interaction with step 6:** the accept answer wins for the same generation. If the timer fires
before the answer is sent, the timeout must lose the claim, **block** on `offer.ch` until
`HandleAccept` sends the outcome, and return `offerAccepted`, so `sendRequestsSequentially` records
`accepted` and closes the trace instead of a timeout skip.

### 4.2 HTTP `POST /api/v1/driver/rides/:id/accept` (canonical)

| Outcome | Status | Body |
| --- | --- | --- |
| assignment committed | `200` | `{"message":"ride accepted"}` |
| no live offer for **this** driver (expired/withdrawn/other driver) | `404 NOT_FOUND` | `{"error":{"code":"NOT_FOUND","message":"no active offer for this ride"}}` |
| ride no longer pending (cancelled/taken) | `409 CONFLICT` | `{"error":{"code":"CONFLICT","message":"ride is no longer available"}}` |
| malformed `:id` | `422 VALIDATION_ERROR` | `{"error":{"code":"VALIDATION_ERROR","message":"invalid ride id"}}` |
| repo/write failure | `500 INTERNAL` | `{"error":{"code":"INTERNAL","message":"failed to accept ride"}}` |

`200` is returned **only after** `AssignDriver` committed. A repo error is never a 2xx.

**Error classification (both the HTTP and WS funnels):** the handler must not rely on a raw type
assertion. Today `AcceptRide` type-asserts `*service.DispatchConflictError`
(`internal/handler/ride.go:686`), so a wrapped `repository.ErrConflict` returned by `AssignDriver`
(`internal/repository/ride_repo.go:424`) falls through to `400 BAD_REQUEST`. Require sentinel
mapping instead:

- `errors.Is(err, repository.ErrConflict)` (and `errors.As(err, &conflict)` where
  `conflict *service.DispatchConflictError`, if the typed error is kept) → `409 CONFLICT "ride is
  no longer available"`.
- `errors.Is(err, service.ErrNoActiveOffer)` / `errors.Is(err, service.ErrNotOffered)` →
  `404 NOT_FOUND "no active offer for this ride"`.
- any other error → `500 INTERNAL "failed to accept ride"`, with the cause logged.

`respondRepo` already maps `repository.ErrConflict` to `409`
(`internal/handler/respond.go:143-151`), but the accept handler must classify the sentinels itself
(or use `respondRepo` for the repo-error branch) rather than depend on the `DispatchConflictError`
type assertion. The WS hub's failure-frame classification (`internal/websocket/hub.go:185-191`) must
use the same `errors.Is`/`errors.As` predicates so a wrapped conflict produces `RIDE_NOT_PENDING`
and not an `OFFER_EXPIRED`/generic failure.
Update the handler annotations at `internal/handler/ride.go:670-680` (currently `400` and the wrong
`@Router /api/v1/rides/{id}/accept`).

### 4.3 WS frames (canonical, verbatim)

Failure frame, sent to the accepting driver on any accept failure
(`OFFER_EXPIRED` = no parked offer, `NOT_OFFERED` = offer belongs to another driver,
`RIDE_NOT_PENDING` = the conditional write found the ride cancelled/taken):

```json
{"type":"ride.accept_failed","data":{"ride_id":"<uuid>","code":"OFFER_EXPIRED|RIDE_NOT_PENDING|NOT_OFFERED","message":"<public sentence>"}}
```

`message` is a fixed public sentence (never `err.Error()`), e.g.
`"this offer has expired"`, `"this ride is no longer available"`, `"this offer was not sent to you"`.
The cause is logged, per the `[errors]` invariant.

Offer-closed frame, sent to the offered driver whenever the server-side offer stops being
actionable:

```json
{"type":"ride.offer_closed","data":{"ride_id":"<uuid>","reason":"expired|declined|cancelled|accepted_elsewhere|withdrawn"}}
```

Emission points:

| Reason | When |
| --- | --- |
| `expired` | `offerRideToDriver` **wins the parked-generation claim** after `offerTimeout` (`internal/service/dispatch.go:430-434`, committed in `a39129a`; §4.1.1 not yet applied): no answer was buffered and the entry is still present under this token. If `HandleAccept`/`WithdrawOffer` already claimed (deleted) the generation, this frame is **suppressed** and the timeout performs a **blocking receive** on the claimant's guaranteed answer and returns that outcome (§4.1.1). |
| `declined` | `DeclineOffer` processes this driver's decline (`internal/service/dispatch.go:389`). |
| `cancelled` | `RideService.CancelRide` withdraws via `WithdrawOffer` (§3). |
| `accepted_elsewhere` | a parked offer is withdrawn because the ride was assigned elsewhere. |
| `withdrawn` | generic abort/no-longer-offerable path (e.g. dispatch loop abort). |

### 4.4 Cancel fan-out (canonical)

`ride.updated` with this data must reach the rider, the assigned driver, **and the currently-offered
driver** (from `WithdrawOffer`) when distinct. The assigned-driver recipient set is derived from the
**post-write re-read `fresh.DriverID`**, never the pre-write `ride.DriverID`: a concurrent
`AssignDriver` may commit between the cancel's read and its conditional write (the cancel still
commits because `accepted` is in `expectedFrom`), and only the fresh row names the newly assigned
driver — so the accept-then-cancel ordering still notifies them (§5.1).

```json
{"type":"ride.updated","data":{"ride_id":"<uuid>","status":"cancelled","cancelled_by":"rider"}}
```

`cancelled_by` is the actor (`"rider"` or `"driver"`). Push notifications follow the same
recipient set, deduplicated (`internal/service/ride.go:425-427`). The offered driver's client can
therefore end a phantom accepted placeholder in a terminal state. This is the server half of the
driver-app bug; the driver-app plan adopts it verbatim.

### Acceptance criteria

- [ ] WS and HTTP accept go through `HandleAccept`; no caller invokes the write directly.
- [ ] The assignment is attempted **exactly once** per accepted offer — the loop's
      `offerAnswer` handling records the outcome but never calls the assignment write, and no
      false `accept_failed` is logged after a successful accept.
- [ ] A different driver answering an offer gets 404/`NOT_OFFERED`; the offered driver is **not**
  assigned and the real offer is untouched (force-assign hole closed).
- [ ] The accept handler classifies wrapped `repository.ErrConflict` as `409` and
  `ErrNoActiveOffer`/`ErrNotOffered` as `404` via `errors.Is`/`errors.As`, never a raw type
  assertion or a `400`.
- [ ] An expired/withdrawn offer gets 404/`OFFER_EXPIRED`, never a false `200`.
- [ ] A cancelled/taken ride gets 409/`RIDE_NOT_PENDING`, never a false `200`.
- [ ] The HTTP accept closes the parked offer, so the dispatch loop does not keep offering and
      does not record `offer_timeout` for an assigned ride.
- [ ] **A committed accept never produces `ride.offer_closed` `reason:"expired"` for that driver,
      even when the accept answer races the 30 s timeout.** The timeout either claims the parked
      generation first (so no accept can commit) or observes the claim and **blocks** for the
      claimant's guaranteed answer, returning the accept outcome, with no `skipOfferTimeout`
      recorded (§4.1.1).
- [ ] The exact frame names/shapes above are pinned by tests and are not renamed.

---

## 5. Tests and verification

### 5.1 Service / race tests (add or update)

- `TestCancelWinsAgainstConcurrentAccept` — accept commits first / cancel reads `accepted`; cancel
  still commits, the ride ends `cancelled`, the driver is notified. **Accept-then-cancel ordering
  explicitly: `AssignDriver` commits, then the cancel commits; the newly assigned driver (named only
  by the post-write `fresh.DriverID`) receives `ride.updated {status:"cancelled"}`.**
- `TestAcceptLosesAgainstConcurrentCancel` — cancel commits first; `AssignDriver` returns 0 rows;
  `HandleAccept` returns a conflict, no assignment, driver gets `ride.accept_failed` +
  terminal `ride.updated`.
- `TestAcceptAssignsExactlyOnce` — a fake repo counts `AssignDriver` calls; a successful
  `HandleAccept` plus the loop's `offerAnswer` handling yields **exactly one** call, and no false
  `accept_failed` skip/log is emitted after a successful accept (regression for the double
  assignment, §4.1 step 6).
- `TestNoOfferSentAfterAcceptOrCancel` — the ride is accepted/cancelled between candidates; the
  loop's per-candidate re-read (§3.4) stops it, so **no `ride.offer` frame reaches a later
  candidate** and the trace records `not_pending`/terminal.
- `TestTwoConcurrentCancelsWriteOneEvent` — one conditional write wins, the other re-reads and
  returns the same fresh ride; exactly one `ride_events` row.
- `TestCancelVsFinishWithoutDriver` — `no_driver_available` write returns `false`, no push is sent,
  and the ride stays `cancelled`.
- `TestArrivalLostRaceIsLoggedAndSwallowed` — cancel wins `accepted`, arrival `AdvanceStatus`
  returns conflict, log line present, no `driver_arrived` event/broadcast/push
  (`internal/service/arrival_test.go`).
- `TestCancelReturnsFreshTimestamps` — `cancelled_at != nil`, `updated_at` > `created_at` /
  at least the commit time. Must assert against a **re-read** result: the test double's
  `FindByID` returns a copy and `UpdateRideStatusFrom` mutates a different stored struct, so the
  returned ride is demonstrably not the pre-write struct (§1.4).
- `TestCancelIdempotentRepeatDoesNotDuplicate` — second cancel `200`, no second event/broadcast.
- `TestCancelAuthorizationRider` / `TestCancelAuthorizationDriver` — wrong caller →
  `ErrNotRideRider`/`ErrNotRideDriver`, no write.
- `TestHandleAcceptRejectsOtherDriver` — a driver that is not the offered candidate gets
  `ErrNotOffered`; **assert the offered driver is NOT assigned (`AssignDriver` never called for
  them) and the parked offer is untouched** (still accept-able by the real offered driver), closing
  the force-assign hole.
- `TestHandleAcceptExpiredOfferReturnsError` — after a simulated timeout, no false success.
- `TestNoExpiredOfferClosedAfterCommittedAccept` — **deterministic boundary test for §4.1.1**: a
  fake repo's `AssignDriver` commits the assignment, signals `committed`, then blocks on a release
  channel; the test waits past the shrunken `offerTimeout` so the timer fires while the assignment
  is committed and the accept answer has **not** been sent yet, then releases the accept. The test
  pins the receive semantics: after losing the claim, the timeout branch must **block** on
  `offer.ch` — never re-check non-blocking, return `offerTimedOut`, or emit `expired` — until the
  released `HandleAccept` sends its answer; the accept goroutine must not be blocked by the timeout
  branch. Assert: `HandleAccept` returns `nil` and `AssignDriver` was called **exactly once** for
  the offered driver; `offerRideToDriver`/the loop returns the success outcome (the trace ends
  `accepted`, never `candidates_skipped`); the test hub recorded **no** `ride.offer_closed` with
  `reason:"expired"`; and **no** `skipOfferTimeout`/`offer_timeout` skip was recorded for the
  assigned ride. The existing timeout-only test must still emit exactly one `expired` when no accept
  claims the offer.
- `TestHandleAcceptWrappedConflictMaps` — a fake `AssignDriver` returns a *wrapped*
  `repository.ErrConflict`; classification is `409`/`RIDE_NOT_PENDING`, never `400`
  (`errors.Is`, §4.2).
- `TestDispatchLoopStopsPromptlyOnWithdraw` — `WithdrawOffer` wakes the loop; assert completion
  without waiting for `offerTimeout`.

### 5.2 Handler / HTTP tests

- `TestCancelRideHandlerOwnership404` (rider on another's ride; driver on an unassigned ride).
- `TestCancelRideHandlerMalformedID422`.
- `TestCancelRideHandlerRepeatIs200` and `TestCancelRideHandlerFreshTimestamps`.
- `TestCancelRideHandlerTerminalIs409`.
- `TestAcceptRideHandlerNoOffer404`, `TestAcceptRideHandlerRideNotPending409`,
  `TestAcceptRideHandlerMalformedID422`, `TestAcceptRideHandlerSuccessOnlyAfterCommit`.
- `TestAcceptRideHandlerWrappedConflict409` — a `repository.ErrConflict` wrapped by the repo (not a
  raw `*service.DispatchConflictError`) answers `409 CONFLICT`, and `ErrNoActiveOffer`/`ErrNotOffered`
  answer `404 NOT_FOUND`; neither falls through to `400` (§4.2).
- Keep/adapt `tests/ride_lifecycle_test.go:385` (`TestRideCancelBeforeAccept`) and
  `tests/ws_push_test.go:131` (`TestWSRiderReceivesCancel`). **`TestRideCancelBeforeAccept` is
  currently status-only** (`tests/ride_lifecycle_test.go:412-414` asserts just
  `ride.status == "cancelled"`); extend it to assert the fresh `cancelled_at` is non-NULL and
  `updated_at` moved, so it covers the incident's stale-timestamp symptom too.

### 5.3 WS frame tests

- `TestWSAcceptFailedFrameOnExpiredOffer` → `OFFER_EXPIRED`.
- `TestWSAcceptFailedFrameNotOffered` → `NOT_OFFERED`.
- `TestWSAcceptFailedFrameRideNotPending` → `RIDE_NOT_PENDING`.
- `TestWSOfferClosedOnRiderCancel` → `ride.offer_closed` `reason:"cancelled"`.
- `TestWSOfferClosedOnTimeout` → `reason:"expired"`. The complement — **no** `expired` frame after
  a committed accept, even when the timer and the accept answer race — is the deterministic
  `TestNoExpiredOfferClosedAfterCommittedAccept` in §5.1.
- `TestWSRiderCancelReachesOfferedDriver` → the offered driver receives both `ride.offer_closed`
  and `ride.updated {status:"cancelled",cancelled_by:"rider"}` even with `driver_id` NULL.

### 5.4 DB-backed integration test

Under `//go:build integration` in package `repository` (reuse `createRidesTable` at
`internal/repository/testdb_integration_test.go:48`), e.g.
`internal/repository/ride_status_transition_integration_test.go`:

- `TestRideRepoUpdateRideStatusFromRejectsStaleExpectedStatus` — insert `pending`; transition
  `pending → accepted` returns `true`; transition with `expectedFrom={"pending"}` returns `false`
  and the row stays `accepted`.
- `TestRideRepoUpdateRideStatusFromNoDriverAvailable` — **required gate for the CAS form**: `pending →
  no_driver_available` returns `true` and sets `updated_at` against real Postgres, proving the
  no-timestamp-column SET clause survived the `UpdateRideStatusFrom` replacement (the defect itself
  was fixed by the landed `[dispatch]` hotfix).
- `TestRideRepoUpdateRideStatusFromCancelFromAccepted` — `accepted → cancelled` returns `true`
  and sets `cancelled_at`.
- Optionally `TestRideRepoAssignDriverAfterCancelConflicts` — `AssignDriver` after a cancel returns
  `ErrConflict`.

### 5.5 Verification commands

```bash
make test
make lint
make test-integration
gofmt -w <touched-files> && go vet ./...
```

Mocks in `tests/testutil` must move in lockstep: a mock must be able to return the failure its
production counterpart can (`parent/AGENTS.md` / STATUS Invariants).

---

## 6. Decisions (recommendations — product owner confirms)

| # | Decision | Recommendation | Rationale / app impact |
| --- | --- | --- | --- |
| a | Concurrent rider cancel vs committed accept | **Rider cancel wins**; the driver is notified and no assignment survives | `accepted` is in the cancel `expectedFrom` set, so a cancel that lands after `AssignDriver` still commits. The rider is the customer and must not be trapped; the driver gets `ride.updated cancelled` and must treat it as terminal even after an optimistic accept. |
| b | Repeat cancel of an already-cancelled ride | **`200` idempotent** with the current ride | Safe retry; no second event/broadcast/push. Defensive `WithdrawOffer` still closes a phantom offer. |
| c | Cancel from `in_progress`/`completed` | **`409 CONFLICT`** (was blanket `400`) | It is a state conflict, matching `ErrConflict`/`ErrDestinationLocked`; the app should show a terminal message and must not retry. `400` was the incident symptom and hides ownership/outage distinctions. |
| d | Duplicate cancel event/push on idempotent repeats | **Suppress** the duplicate `ride_events` row and the duplicate participant broadcast/push | Idempotency means one committed cancellation. The only exception is the defensive `ride.offer_closed` when a parked offer genuinely still exists. |
| e | Driver cancel of `accepted`/`driver_arrived`; "trip goes back to dispatch" | **Keep the server-permitted driver cancel** for `accepted`/`driver_arrived`, with `cancelled_by:"driver"`; the ride becomes terminally `cancelled` and is **never** re-dispatched. Do not allow `pending` (no assignment). Remove/repair the driver-app "goes back to dispatch" copy | Re-dispatch would need a new state/event, a rider notification, and a dispatch re-arm; that is a separate product plan. If product wants to forbid driver cancels instead, that is a one-line `validTransitions` change but strands drivers with no exit; not recommended now. |

---

## 7. Out of scope / residual

- **Cancellation fee:** always `0` today (`internal/model/ride.go:17`, `rides.cancellation_fee`
  default `0`, migration `005_create_rides.up.sql:23`). No fee logic in this plan.
- **Rider/driver client code:** owned by `rider-planner` / `driver-planner`. The driver-app plan
  adopts §2.1, §4.2, §4.3, §4.4 verbatim (including the `ride.accept_failed` / `ride.offer_closed`
  names and the 404/409/422 map).
- **No migration is expected:** the `rides` status CHECK already includes `no_driver_available`
  (`internal/database/migrations/005_create_rides.up.sql:5-10`, status at `:9`), and
  `cancelled_at`/`updated_at` exist. If a new column becomes necessary, append a migration per the
  append-only invariant.
- **No routing, fare, elevation, or auth changes.**
- **Coordination with the open `01_[arrival]_accept_time_evaluation.md` (stage `01` of the
  `[arrival]` chain; depends on this plan):** its accept-time
  `accepted→driver_arrived` transition must use this plan's `UpdateRideStatusFrom` (one
  conditional write), not a second/parallel guard, and it adopts `ErrTransitionConflict` verbatim.
  Its evaluation must remain non-fatal to the accept and must not fire `ride.nearby`, per that
  plan. This plan stays the unnumbered chain head; it gains no dependency from that one.
- **Residual:** `ride_events.from_status` on a cancel can be approximate if the read raced another
  transition (the authoritative `status`/timestamps are still correct). Ancillary-row best-effort
  rules in `api_plans/STATUS.md:694-696` apply.

---

## Evidence map (baseline snapshot `0a11b95`; partial implementation committed `a39129a` on 2026-10-19 — §4.1.1 is **not yet applied**)

| Claim | Evidence |
| --- | --- |
| `CancelRide` read → check → unconditional write → mutate only `Status` → stale response | `internal/service/ride.go:383-408,419-430` |
| Cancellable edges | `internal/service/ride.go:119-126` |
| `AdvanceStatus` read → unconditional write | `internal/service/ride.go:433-445` |
| Owner-check precedent | `internal/service/ride.go:147,641-650`; handler mapping `internal/handler/ride.go:366` |
| Unconditional repo write + fixed status columns + empty `no_driver_available` column | `internal/repository/ride_repo.go:299-329` (SQL `:320-323`) |
| `AssignDriver` is the one conditional write | `internal/repository/ride_repo.go:411-426` (`WHERE … status='pending'` `:414`) |
| `finishWithoutDriver` unconditional terminal write | `internal/service/dispatch.go:167-180` (write `:172`) |
| Post-offer pending re-read then write | `internal/service/dispatch.go:275-289` (`:280`) |
| Offer registration/defer/`ride.offer`/timeout | `internal/service/dispatch.go:317-355`; timeout `internal/service/dispatch_observability.go:216` |
| Timeout vs accept race: unconditional `expired` frame; accept claim/answer ordering | **committed in `a39129a` (partial implementation; §4.1.1 not yet applied):** `internal/service/dispatch.go:430-434` (`recordSkip(skipOfferTimeout)` + `sendOfferClosed(..., "expired")`); `HandleAccept` claim/delete `:482-498`, authoritative `acceptRide` `:500`, non-blocking answer `:504-507`; parked `chan offerAnswer` buffered 1 `:383,388`; `WithdrawOffer` delete/answer `:532-549` |
| `HandleAccept` ignores `driverID`, no result | `internal/service/dispatch.go:364-372` |
| `DeclineOffer` driver match precedent | `internal/service/dispatch.go:389-396` |
| HTTP accept bypasses the funnel + raw `DispatchConflictError` type assertion | `internal/service/dispatch.go:400-481`; `internal/handler/ride.go:681-694` (assertion `:686`) |
| Wrapped repo conflict from the assignment write | `internal/repository/ride_repo.go:424` (`ErrConflict` wrapped with `sql.ErrNoRows`); `respondRepo` 409 map `internal/handler/respond.go:143-151` |
| WS accept only logs failure | `internal/websocket/hub.go:185-191`; interface `:36-39` |
| Cancel handler: role only, no UUID, all errors → 400 | `internal/handler/ride.go:553-561` |
| Routes; rider cancel not role-gated; driver role gate is the group middleware | `internal/router/router.go:247,253,256,271,276` (`/queue` is `:250`) |
| Construction order (setter required) | `internal/router/router.go:161,172-173` |
| Arrival logs/swallows `AdvanceStatus` errors | `internal/service/arrival.go:82-86` |
| Mocks: `FindByID` copy-on-read; update mutates stored; `AssignDriver` guard | `tests/testutil/mock_repos.go:391-399,627-655,730`; stub repos cited in §1.4 |
| `TestRideCancelBeforeAccept` asserts status only today | `tests/ride_lifecycle_test.go:412-414` |
| Status CHECK includes `no_driver_available` | `internal/database/migrations/005_create_rides.up.sql:5-10` (status `:9`) |
| Outbound envelope / `RideUpdateData` | `internal/websocket/messages.go:5-22` |
| Cancellation fee default 0 | `internal/model/ride.go:17`; migration `005_create_rides.up.sql:23` |

**Drift to report (not fixed by this plan):**

- **The implementation committed in `a39129a`** moved the offer/timeout block:
  `offerRideToDriver` is now `internal/service/dispatch.go:373-436` (timeout `:430-434`),
  `WithdrawOffer` is `:532-549`, and `HandleAccept` is `:481-526`. The evidence-map row that cites
  `:317-355` is the pre-implementation snapshot (`0a11b95`); the timeout row below cites the current
  tree.
- `api_plans/STATUS.md:201-204` cites the zero-candidate `finishWithoutDriver` call at
  `dispatch.go:112` and the helper at `:127-138`/`:135`/`:137`; the current tree has the call at
  `:150`, the helper at `:167-180`, the early return at `:176`, and the push at `:178`.
- `internal/handler/ride.go:680` documents `@Router /api/v1/rides/{id}/accept`, but the real route
  is `/api/v1/driver/rides/:id/accept` (`internal/router/router.go:253`); there is no
  `/api/v1/rides/{id}/accept`. The cancel annotation (`:552`) documents only the rider route even
  though the same handler serves the driver route (`router.go:256`).
- ~~`internal/repository/ride_repo.go:306-323`: `no_driver_available` produces invalid SQL on a
  real Postgres, so `finishWithoutDriver` always takes its error branch and never pushes.~~
  **Resolved 2026-10-19 by the landed `[dispatch]` hotfix:** `rideStatusTimestampColumn` +
  `updateRideStatusQuery` (`internal/repository/ride_repo.go:305-355`) emit the no-column form and
  the DB-backed test passes; this plan must keep that form in `UpdateRideStatusFrom`.
