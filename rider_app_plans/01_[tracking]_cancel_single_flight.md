---
tag: tracking
depends_on: ["api_plans/[rides]_cancel_accept_race.md"]
status: open
---

# 01 [tracking] Single-flight rider cancel + honest cancel status handling

> **Owner:** `rider-planner`. **Plan only** (no source/test edit in this authoring pass).
> **Chain position:** stage `01` of the rider `[tracking]` chain. It is numbered because
> `depends_on` names an **open** plan — the canonical server contract
> `api_plans/[rides]_cancel_accept_race.md` (skill: non-empty *open-plan* `depends_on` ⟺ `NN_`).
> The guard half is useful independently, but the status branches below are written against that
> plan's contract and can only be exercised against a real server once it lands.

## Incident and rider half (2026-10-19)

A rider fired several quick cancel requests for the same ride while a driver was accepting. The
first answered `200`; the server later answered the driver's cancels with `400` and the driver got
stuck (server root cause owned by the API plan). This plan owns only the rider's contribution:
**multiple quick requests for one cancellation**.

Verified in the tree:

- `ActiveRideScreen._cancelRide` has **no in-flight guard**: it reads the ride id, awaits the
  confirm dialog, posts, then reads the shared cancel state — with no re-entry check before or
  during the dialog/POST (`rider_app/lib/features/home/presentation/active_ride_screen.dart:174-213`).
- The **Cancel Ride** button is always enabled (`:919-924`, `onPressed: _cancelRide`), and the
  overlay back arrow reuses the same handler (`_handleBack` `:565-572`), so both surfaces can open
  another confirmation while a cancel is already in flight.
- `DriverMatchingScreen` already has a functional single-flight guard (`_cancelInFlight`
  `driver_matching_screen.dart:23`, early return `:78`, set/reset `:87-89`, disabled button `:182`).
  It must not be duplicated or regressed.
- The provider already exposes `isCancelling` (`home_provider.dart:229,236,244,251`), but **no
  production widget reads it** (only `home_provider_test.dart`); it becomes `true` only inside
  `cancelRide` (`:345`), i.e. *after* the confirm dialog, so it cannot guard the dialog itself.

## Canonical contract consumed (do not redefine)

Source: `api_plans/[rides]_cancel_accept_race.md` §2.2, quoted verbatim:

| Outcome | HTTP |
| --- | --- |
| success / authorized repeat cancel | `200` `{"ride":<fresh ride>}` |
| malformed `:id` | `422 VALIDATION_ERROR "invalid ride id"` |
| ride missing or not the caller's | `404 NOT_FOUND "ride not found"` |
| `in_progress`/`completed`/`no_driver_available` | `409 CONFLICT "ride can no longer be cancelled"` |
| repo/write failure | `500 INTERNAL "failed to cancel ride"` |

Additional contract facts relied on (§2.2, §6b):

- A repeat cancel of an already-cancelled ride is **`200` idempotent** with the current ride (no
  second event/broadcast/push). The rider therefore relies on the server converging a repeat,
  **but keeps a client guard** so a double tap never posts twice in the first place; a retry after
  a *lost response* (e.g. a timeout the server actually committed) still converges to `200` and
  the success path.
- Cancellable set: `pending`, `accepted`, `driver_arrived`. A concurrent committed accept does not
  block the rider's cancel (§6a, cancel wins); `in_progress`/`completed`/`no_driver_available`
  are `409`.
- The rider app must **not** add a retry loop. A `5xx`/transport failure leaves the action
  retryable by a fresh user tap; a `409` is terminal for this action (show the message, do not
  re-post automatically).

**Dependency state (verified):** the API is still unfixed today — every cancel error is
`fail(c, 400, "BAD_REQUEST", "ride cannot be cancelled", err)` (`internal/handler/ride.go:553-561`)
and `RideService.CancelRide` still has the old signature/read-check-write
(`internal/service/ride.go:382-408`). Until the API plan lands, a real `400` must stay on the
generic failure path (`failed`), **not** be reclassified as conflict. The `404`/`409` branches are
specified against the canonical contract and are unit/widget-tested with mocks.

## Evidence map (verified in this tree, commit `0a11b95` + working tree)

| Claim | Evidence |
| --- | --- |
| No guard in the active-ride cancel; confirm → POST → snackbar/home | `rider_app/lib/features/home/presentation/active_ride_screen.dart:174-213` |
| Confirm dialog itself, then `await cancelRide` | `active_ride_screen.dart:178-199` |
| `cancelError` snackbar / success snackbar + `_goHomeAfterCancel` | `active_ride_screen.dart:202-212` |
| Button always enabled | `active_ride_screen.dart:919-924` |
| Back arrow reuses the cancel path | `active_ride_screen.dart:565-572` |
| WS `cancelled` branch already shows success + leaves | `active_ride_screen.dart:638-659` (snackbar `:651-652`, exit `:654`) |
| One-shot navigation exit (`_leaving`) | `active_ride_screen.dart:61,553-559` |
| Matching-screen guard precedent | `rider_app/lib/features/home/presentation/driver_matching_screen.dart:23,78,87-89,182` |
| `isCancelling`/`cancelError` state, copyWith resets `cancelError` | `rider_app/lib/features/home/data/home_provider.dart:225-255` (`cancelError` always assigned `:252`) |
| `cancelRide` posts and maps failures to one string | `home_provider.dart:344-363`; endpoint `home_provider.dart:347` → `core/api/endpoints.dart:16` |
| `_errorMessage` reads the API `{"error":{"message"}}` envelope | `home_provider.dart:375-387` |
| Status code is available on the mapped exception | `shared/lib/src/api/api_exceptions.dart:3-10,85-96`; interceptor maps non-2xx `shared/lib/src/api/api_client.dart:40-94` (`:75-78`) |
| `AppButton` disables on `onPressed == null` | `shared/lib/src/components/app_button.dart:42-43` |
| Existing active-ride cancel tests | `rider_app/test/features/home/presentation/active_ride_screen_test.dart:488-520` (confirm + POST + home), `:522-541` (Keep Ride), `:543-577` (back arrow), `:579-600` (WS cancel) |
| Existing provider cancel tests | `rider_app/test/features/home/data/home_provider_test.dart:11-76` |
| Existing matching cancel test | `rider_app/test/features/home/presentation/driver_matching_screen_test.dart:113-140` |
| Test fixture supports async/delayed replies | `DioAdapter.replyCallbackAsync` (`http_mock_adapter` 0.6.1) + `Completer`; fixture `active_ride_screen_test.dart:206-291` |

**Drift found while verifying (report, do not silently fix):**

1. The brief says the 5 s current-ride poll reconciles a server-side cancel "if the screen is
   still open". It does **not run on `ActiveRideScreen`**: `DriverMatchingScreen` stops it before
   `context.go('/active-ride')` (`driver_matching_screen.dart:117,136`), `ActiveRideScreen` never
   starts it (only `reset()` at `:547,557`), and `checkOnce()` is one-shot
   (`current_ride_provider.dart:96`). On the active screen reconciliation comes from the WS
   `rideStatusProvider` listener (`:638-659`) and the ride-detail read; do not specify a poll
   dependency here.
2. `isCancelling` is written but has no production consumer (grep: `home_provider.dart` + tests).
3. `DriverMatchingScreen` sets/clears `_cancelInFlight` without `setState`/`finally`
   (`driver_matching_screen.dart:87-89`): the early return keeps it single-flight, but the
   disabled visual may not rebuild and an escaped exception would leave it stuck. Out of scope;
   do not change it, but pin the POST count with a regression test.
4. Two success feedback paths already exist on the active screen: the POST path
   (`:209-211`) and the WS `cancelled` listener (`:651-652`). A fast WS echo can show the same
   SnackBar twice even with a perfect single-flight guard. Fix the feedback, not only the POST.

## Required work

### 1. Single-flight guard on `ActiveRideScreen._cancelRide` (rider_app)

Use a **local** `bool _cancelInFlight = false` on `_ActiveRideScreenState`, not
`RideCreationState.isCancelling` (decision d below). The guard must be set **synchronously before
`showDialog`** and cleared on every exit:

- At entry: `if (_cancelInFlight || _leaving) return;` then `setState(() => _cancelInFlight = true);`
  before reading/awaiting anything else. Setting it before the dialog is what prevents a second
  tap from stacking a second confirm dialog; `_leaving` prevents a late tap from reopening a
  cancel dialog as the screen is leaving.
- Wrap the dialog + POST + handling in `try { … } finally { if (mounted) setState(() => _cancelInFlight = false); }`.
  - Keep the existing `rideId == null` and `confirmed != true || !mounted` early exits; the
    `finally` clears the flag for them.
  - On unmount there is nothing to reset (the `State` is discarded); do not call `setState`.
- The handler covers both entry points (`Cancel Ride` button and `_handleBack`) — no second guard.
- Exactly one `POST /api/v1/rides/:id/cancel` per confirmed cancellation attempt; no duplicate
  dialog, success SnackBar, or navigation.

### 2. Disable the button while in flight

- Bind the button to the same busy signal: `onPressed: _cancelInFlight ? null : _cancelRide`
  (`active_ride_screen.dart:919-924`). `AppButton` already disables on a null callback
  (`shared/lib/src/components/app_button.dart:42-43,83`), so the UI cannot issue a second request
  while the POST is in flight (or while the dialog is open).
- Because the flag is mutated through `setState`, the disabled state actually rebuilds. (The
  matching screen's plain-field guard has no such rebuild; do not copy that detail.)

### 3. Consume the API status semantics honestly

Keep `cancelError` as the matching screen's contract and add a **typed outcome returned by
`cancelRide`** rather than parsing strings or adding a fragile nullable state field:

```dart
enum CancelOutcome { success, notFound, conflict, failed }

Future<CancelOutcome> cancelRide(String rideId) async { … }
```

In `RideCreationNotifier.cancelRide` (`home_provider.dart:344-363`):

- Keep setting `isCancelling`/`cancelError` exactly as today (matching screen and existing tests
  unchanged). Derive the status from the mapped exception first, then the raw response:
  `final mapped = e.error; final code = mapped is ApiException ? mapped.statusCode : e.response?.statusCode;`
  in the `on DioException` arm, and `e.statusCode` in the `on ApiException` arm.
- Return `success` on the `2xx` path (including an idempotent repeat), `notFound` on `404`,
  `conflict` on `409`, `failed` for everything else (`400` until the API plan lands, `422`, `5xx`,
  transport errors with no status).
- Do **not** change `_errorMessage` and do not add a status field to `RideCreationState`
  (its `copyWith` assigns `cancelError` unconditionally, `:252`; a nullable field would need extra
  sentinel machinery for no benefit). `cancelError` still carries the API `message` for `409` and
  for the generic error SnackBar.
- Do not add retries, timers, or automatic re-POSTs.

In `_cancelRide`, switch on the returned outcome after the `mounted` check:

| Outcome | UI behavior |
| --- | --- |
| `success` (`200`, incl. authorized repeat) | Show the one success SnackBar (`Ride cancelled successfully`) and `_goHomeAfterCancel()`. |
| `notFound` (`404`) | **Silent reconcile + home**: call `_goHomeAfterCancel()` with no error SnackBar. It already marks the pickup return and resets `currentRideProvider` (`active_ride_screen.dart:553-559`). Do not show `ride not found`. |
| `conflict` (`409`) | Show the API message from `cancelError` (fallback `'Ride can no longer be cancelled'` only if null), **stay on the trip**, no navigation, no automatic retry. The WS listener / ride-detail read remain the reconciliation channel (no poll runs here — see drift 1). |
| `failed` (`5xx`, `422`, `400` today, transport) | Show the existing error SnackBar (`cancelError`), stay on the trip; the reset guard leaves the action retryable by a fresh user tap. |

`404` must not be retried as a cancel and must not render a scary generic error: the endpoint
deliberately answers the same `404` for "missing" and "not the caller's" (no existence leak), so
the only truthful rider action is to leave the dead trip view.

### 4. One success feedback, not two (small, in scope because it is the same symptom)

Route both success sources through one helper, e.g. `_acknowledgeCancelled()`:

- guard with a local `bool _cancelAcknowledged = false`; show
  `SnackBar('Ride cancelled successfully')` only on the first call, then `_goHomeAfterCancel()`.
- Call it from the `success` outcome in `_cancelRide` **and** from the WS `cancelled` branch
  (`active_ride_screen.dart:648-654`) instead of the duplicated snackbar + exit.
- This keeps the driver-initiated cancel behavior (WS is the only signal there) and removes the
  duplicate when the server echoes `ride.updated cancelled` for the rider's own POST.

### 5. Matching screen: verify, do not duplicate

- Keep `DriverMatchingScreen._cancelInFlight` as the only guard there
  (`driver_matching_screen.dart:23,78,87-89,182`). Do not add a second guard, a provider guard, or
  a shared widget.
- Add the regression test in §Tests so the existing early return is pinned. Do not "fix" its
  missing `setState`/`finally` in this plan (out of scope; recorded as drift 3).

### 6. No shared-package change

Explicitly: **no `shared/` change is required or permitted by this plan.** The typed
`ApiException.statusCode` (`shared/lib/src/api/api_exceptions.dart:3-10`), the status mapper
(`:85-96`), and `AppButton`'s `onPressed == null` disable contract (`shared/lib/src/components/app_button.dart:42-43`)
already exist. Import them from the barrel as today; do not add a shim and do not move any app file
into `shared/`.

## Tests

### `rider_app/test/features/home/presentation/active_ride_screen_test.dart`

Hold the POST in flight with `replyCallbackAsync` + a `Completer` (no real sleeps), and count
handler invocations — the fixture already builds a real `DioAdapter` (`:206-291`).

- **`'a second cancel tap while the POST is in flight posts exactly once'`** — confirm once so the
  POST is parked, pump, tap `Cancel Ride` again (and, in a second variant, confirm twice in the
  same frame), complete the parked response; assert the counter is `1`, exactly one
  `Cancel this ride?` dialog ever appeared, and one `Ride cancelled successfully`.
- **`'the Cancel Ride button is disabled while the cancel POST is in flight'`** — parked POST;
  `tester.widget<AppButton>(find.widgetWithText(AppButton, 'Cancel Ride')).onPressed` is `null`;
  after completion it is non-null (or the screen has left).
- **`'an idempotent 200 repeat cancel lands home once'`** — a `200` with a fresh
  `{"ride":{"id":"ride-1","status":"cancelled"}}`; assert home once and one success SnackBar;
  optionally emit the WS `cancelled` echo and assert the SnackBar count stays `1`.
- **`'a 404 cancel goes home without a generic error'`** — `404` with
  `{"error":{"code":"NOT_FOUND","message":"ride not found"}}`; assert `Home` is shown and
  `Ride not found` / `ride not found` is not shown.
- **`'a 409 cancel shows the API message and does not navigate or retry'`** — `409` with
  `{"error":{"code":"CONFLICT","message":"ride can no longer be cancelled"}}`; assert the message
  is visible, `Home` is absent, and the POST counter stays `1` across pumps.
- **`'a 500 cancel shows a retryable error and does not navigate'`** — `500`; assert the API
  message is visible, `Home` absent, the guard reset (a fresh tap opens one new dialog and posts
  exactly once more).

Keep these existing cases green unchanged: `'pressed cancel shows confirmation and posts the cancel
request'` (`:488-520`), `'cancel confirmation negative keeps the ride active'` (`:522-541`),
`'the overlay back arrow routes through the cancel path without popping'` (`:543-577`),
`'WS cancelled event routes home'` (`:579-600`).

### `rider_app/test/features/home/data/home_provider_test.dart` (group `RideCreationNotifier.cancelRide`, `:11`)

- **`'200 returns CancelOutcome.success'`**
- **`'404 returns CancelOutcome.notFound and keeps the API message in cancelError'`**
- **`'409 returns CancelOutcome.conflict'`**
- **`'500 returns CancelOutcome.failed'`**

Keep the existing `isCancelling`/`cancelError` assertions (`:26-75`) — the state contract must not
change.

### `rider_app/test/features/home/presentation/driver_matching_screen_test.dart`

- **`'a second cancel tap while the cancel POST is in flight posts once'`** — same parked-POST
  counting pattern; the guard is the existing `_cancelInFlight` early return
  (`driver_matching_screen.dart:78`). No production change expected.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

- `make flutter-analyze` / `make flutter-test` are **broken from this WSL tree** (they shell out to
  the Windows `melos.bat` via `cmd.exe`, which cannot `cd` the UNC path) — use native Melos as
  above.
- Flutter runs must be **serialized across agents** (one `melos`/`flutter test` at a time); do not
  run concurrent Flutter suites.
- **UNVERIFIABLE here:** Android on-device behavior (rapid taps on a real touch stack, dialog
  dismissal timing) and a real API server running the canonical contract until
  `api_plans/[rides]_cancel_accept_race.md` lands. The `404`/`409`/`500` acceptance is proven by
  the mocked suites against the contract; re-run against the live API after the API plan lands.
- To close: run the targeted suites first
  (`cd rider_app && flutter test test/features/home/presentation/active_ride_screen_test.dart test/features/home/data/home_provider_test.dart test/features/home/presentation/driver_matching_screen_test.dart`),
  then the full `melos run test` (rider counts include the new cases).

## Decisions (recommendations — product owner confirms)

| # | Decision | Recommendation | Rationale |
| --- | --- | --- | --- |
| a | May the rider cancel after the driver accepted? | **Yes — cancel wins.** The client always posts the cancel for the trip on screen; it does not distinguish `accepted` from `pending`. The API commits the cancel over a concurrent accept (§6a) and notifies the driver. | The rider is the customer and must not be trapped; the server is the authority. No client status gate is added in this plan. |
| b | `404` silent or a message? | **Silent + home** (no error SnackBar). `_goHomeAfterCancel()` already reconciles the poll view. | `404` intentionally means "missing *or* not yours"; there is no rider action and a red generic error falsely implies an outage/validation problem. The trip view is dead either way. |
| c | `409` behavior | Show the API message, stay on the trip, never auto-retry. The button re-enables only after the guard resets, so a user-driven retry is possible but produces another `409` (no loop). | `409` is a state conflict (in progress/completed), not an outage; the message is the API's public sentence. |
| d | Busy signal: local `_cancelInFlight` or `RideCreationState.isCancelling`? | **Local `_cancelInFlight`**, set before `showDialog`, reset in `finally`, mutated with `setState`. `isCancelling` is a secondary/provider signal only and must not be the dialog guard. | `isCancelling` becomes true only inside `cancelRide` (`home_provider.dart:345`), i.e. after confirmation, so a quick second tap could still stack a dialog; it is also currently consumed by no production widget. One guard, locally owned, covers dialog + POST + button. |
| e | Success feedback across POST and WS | **One-shot helper/flag** (`_cancelAcknowledged`), used by both paths. | The server's `ride.updated cancelled` can echo the rider's own POST; today both paths show the same SnackBar (`active_ride_screen.dart:209-211` vs `:651-652`) even with one POST. One cancellation = one success message. |
| f | Hide the Cancel button for `in_progress`/`completed`? | **Not in this plan.** Keep the button; `409` + message is the honest outcome. A follow-up may gate visibility on the cancellable set. | Keeps this plan to the single-flight defect; hiding actions changes product surface and would need its own decision. |

## Out of scope

- The API state machine, atomic transitions, offer withdrawal, fan-out and the `400`→`404/409/422`
  remap — owned by `api_plans/[rides]_cancel_accept_race.md`.
- The driver app (its cancel path and optimistic accept) — `driver_app_plans/`.
- The `ride.updated` / `ride.offer_closed` WS protocol shapes.
- The cancellation fee (always `0`; API plan §7).
- `DriverMatchingScreen`'s already-functional guard, its missing `setState`/`finally` detail, and
  its 404/409 presentation.
- Any `shared/` change, new shim, or file move.

## Acceptance criteria

- [ ] `_cancelRide` is single-flight across the confirm dialog and the POST: two rapid invocations
      produce exactly **one** `POST /api/v1/rides/:id/cancel`, one dialog, one success SnackBar and
      one navigation.
- [ ] The `Cancel Ride` button has `onPressed == null` while the cancel is in flight (and during
      the confirmation), driven by the same busy signal.
- [ ] The busy flag is cleared on success, every error outcome, a dismissed/negative dialog, and a
      `rideId == null` early exit; no `setState` after unmount.
- [ ] `200` (including an authorized repeat) → success + `_goHomeAfterCancel()`.
- [ ] `404` → home with no generic error SnackBar.
- [ ] `409` → the API message is shown, no navigation, exactly one POST, no automatic retry.
- [ ] `5xx`/transport → existing error SnackBar, no navigation, action retryable by a new tap.
- [ ] A driver-initiated cancel (`WS cancelled` only) still shows one success message and goes
      home, and the rider's own `200` is not double-acknowledged by the WS echo.
- [ ] `DriverMatchingScreen` still posts once per cancel request (regression test), with no
      second guard added.
- [ ] No `shared/` file changed; no file moved.
- [ ] Existing success/negative/back-arrow/WS cancel tests and the provider state tests still pass.
- [ ] `melos run analyze` clean and `melos run test` green (Linux FVM SDK, serialized).
