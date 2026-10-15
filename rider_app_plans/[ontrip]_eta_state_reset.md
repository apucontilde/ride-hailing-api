---
tag: ontrip
depends_on: ["[ontrip] live driver-arrival ETA (rider_app_plans/STATUS.md → Landed [ontrip])"]
status: open
---

# [ontrip] Per-ride reset of the driver-arrival ETA throttle

> Bug **#30** (`rider_app_plans/STATUS.md` → Known bugs). Residual of the landed `[ontrip]`
> live driver-arrival ETA (R1). Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test`
> (Linux FVM SDK — see Verification). Independent: the only prerequisite is the already-landed R1
> capability (`depends_on` names landed capability, not an open plan), so this plan is unnumbered.

## Problem

`driverEtaProvider` is a global, non-`autoDispose` `StateNotifierProvider` —
`features/home/data/driver_eta_provider.dart:243-246`. `ActiveRideScreen` reads the notifier once
(`features/home/presentation/active_ride_screen.dart:54,77`), seeds it (`:98`), re-feeds it on every
ride-status change (`:638-641`), and calls `_driverEta.stop()` on dispose (`:140`). `stop()`
(`driver_eta_provider.dart:131-134`) cancels only the timer:

```dart
void stop() {
  _timer?.cancel();
  _timer = null;
}
```

It never clears `_referenceFix` (`:86`) or `_lastRequestAt` (`:87`). Those two fields therefore live
for the whole app session, across rides:

- `onRideState` decides "first fix computes immediately" with `final immediate = _referenceFix == null;`
  (`:118`). On every ride after the first, `_referenceFix` is already non-null from the previous ride,
  so `immediate` is **false** even on the first fix after entering `driverApproaching`.
- The early trigger then compares the new driver fix against the **previous ride's** reference fix —
  `_movedEnough(fix, _referenceFix!)` (`:119`; `_movedEnough` `:202-203`). A new ride whose first fix
  is < 150 m from the stale reference fix never triggers until the 30 s tick.
- `_compute` floors on the previous ride's `_lastRequestAt` (`:157-160`), so the first compute is
  delayed up to `minInterval` (5 s) even when it does trigger.

Net: the D4 guarantee ("immediate on the first fix after entering `driverApproaching`", stated in the
code comment `:113-118`) holds only for the session's first ride. The compute, the 5 s floor and the
`300`-unknown honesty are themselves correct; only the per-ride reset is missing.

## Fix

Add a reset of the **throttle bookkeeping** and call it at the ride boundaries.

### 1. Reset method

```dart
/// Clears the per-ride throttle bookkeeping so the next ride's first fix is
/// computed immediately. Does **not** touch [state] or `RideState` — the
/// authoritative ETA and the `300`-unknown contract are untouched.
void _resetThrottle() {
  _referenceFix = null;
  _lastRequestAt = null;
  _lastCompute = null;
}
```

Do not clear `state.etaSeconds`/`state.error` or `RideState.etaSeconds`: the notifier's `state` is
diagnostic, and the displayed value is `RideState.etaSeconds`, which the screen only renders while
`driverApproaching` (`active_ride_screen.dart:1016-1025`). Clearing it would risk blanking a
legitimate value — avoid.

### 2. Call sites (all three ride-boundary paths)

- **Leaving `driverApproaching` / terminal status / dispose.** `onRideState` already calls `stop()`
  for every non-`driverApproaching` status (`:103-106`), and `dispose()` calls `stop()` (`:238`).
  Make `stop()` reset:

  ```dart
  void stop() {
    _timer?.cancel();
    _timer = null;
    _resetThrottle();
  }
  ```

  Every terminal status (`completed`/`cancelled`/`noDriverAvailable`) and every transition out of
  `driverApproaching` goes through `onRideState` → `stop()`, so this covers terminal-status and
  dispose resets (`stop()` is also called from `_tick` `:139` when the status changed underneath it).
- **Entering `driverApproaching`.** Make the entry edge explicit and independent of `stop()`'s
  idempotence — compute the transition before overwriting `_status`:

  ```dart
  final wasApproaching = _status == RideStatus.driverApproaching;
  _status = rideState.status;
  if (_status != RideStatus.driverApproaching) {
    stop();          // cancels + resets
    return;
  }
  if (!wasApproaching) _resetThrottle();   // entering edge, defensive
  start();
  ```

  With the `stop()` reset this is redundant in the simple ride-A → terminal → ride-B path; it exists
  so a future status path that never calls `stop()` cannot reintroduce the leak, and so the
  "entering" intent is visible at the transition.

### 3. Optional hardening (decide, do not silently skip)

A ride change that **stays** in `driverApproaching` (e.g. a `ride.updated` that swaps `ride_id` with
no intermediate terminal status) would not be caught by either reset point. The API state machine
does not produce that today, so it is out of scope — if wanted, track `_rideId` and reset when
`rideState.rideId` changes. Record the decision either way.

## Invariants preserved

- **5 s floor** (`minInterval` `:70`; enforced `:157-160`) stays authoritative **within** a ride —
  including the failed-compute path (existing test `test/features/home/data/driver_eta_provider_test.dart:168-221`).
  Resetting across a ride boundary is the intended D4 behavior, not a floor bypass.
- **`300` = unknown** (`features/home/data/trip_eta.dart:5`; guard `driver_eta_provider.dart:184`)
  unchanged — the reset never calls `applyLiveEta` and writes no value.
- **Keep-previous-on-failure** unchanged (`:189-194`).
- The notifier stays a global `StateNotifierProvider` (no `autoDispose`); session-lifetime state is
  fine — only the throttle bookkeeping was wrong.

## Tests to add — `test/features/home/data/driver_eta_provider_test.dart`

1. **A second ride's first compute is immediate** (the bug's regression test). Ride 1:
   `onRideState(approaching())` → `await pendingCompute`; assert `computations == 1`. Leave the trip:
   `onRideState(approaching(status: 'in_progress'))` → assert `isPolling` is false. Ride 2: a
   **different `rideId`** (extend the `approaching()` helper with a `rideId` parameter) whose first
   driver fix is at the **same simulated wall-clock** (`currentTime` unchanged — inside the 5 s floor)
   and **within 150 m** of ride 1's fix, so both the floor and the movement trigger would suppress a
   request if the state leaked. Assert a second `GET /api/v1/geo/eta` fires (`computations == 2`).
   This single case fails against today's code and only passes once both `_referenceFix` and
   `_lastRequestAt` are reset.
2. **Within-ride floor still holds** — keep/point at the existing `:96-114` and `:168-221` cases.
3. **Terminal-status reset** — repeat (1) using a terminal leave (`no_driver_available`) rather than
   `in_progress`, so the "on terminal status" path is proven, not just "any non-approaching".
4. **Unknown honesty unchanged** — existing `:223-239` stays green.

## Out of scope

- The compute itself, the 300 guard, the request/response shape, the 30 s / 150 m / 5 s values, and
  the per-status display semantics.
- Any change to `active_ride_screen.dart` beyond the already-existing `stop()` call (the fix is
  inside the notifier).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

Bug #30 is only closed when test (1) fails before the change and passes after. If Dart cannot be run,
mark the corresponding STATUS.md landing claim `UNVERIFIABLE` with the exact command above.
