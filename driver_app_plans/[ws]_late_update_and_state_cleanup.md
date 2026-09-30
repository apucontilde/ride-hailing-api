---
tag: ws
depends_on: []
status: open
---

# Late `ride.updated` for a new ride + dead `lastLocation` cleanup

Fixes bugs **#12** and **#2** of `driver_app_plans/STATUS.md` (both in
`driver_app/lib/core/ride/ride_state_notifier.dart`, so they are grouped here).

**Read first:**

- `driver_app/lib/core/ride/ride_state_notifier.dart:86-97` — `_onRideUpdated`; the early return at
  `:92` is bug #12.
- `driver_app/lib/features/trip/presentation/trip_screen.dart:107-113,191,228` — `_finishTrip` /
  `_confirmComplete` are the only callers of `clearRide()`, and only on user action.
- `driver_app/lib/core/ride/ride_state_notifier.dart:13-42,69-80,160-164` — `lastLocation` /
  `clearLocation` plumbing (bug #2).
- `driver_app/lib/core/ride/ride_update.dart:90-100` — `applyTo` maps status → timestamps;
  terminal statuses are `completed` / `cancelled`.
- Tests: `driver_app/test/core/ride/ride_state_notifier_test.dart` (the `lastLocation` assertions
  at `:136-141,159-168` are removed here).

## Gap (verified)

- **#12:** `_onRideUpdated` returns early whenever `held.id != update.rideId`
  (`ride_state_notifier.dart:92`). The held ride is only dropped by `clearRide()`, which fires when
  the driver taps Finish/complete-confirm (`trip_screen.dart:109-113`) — never automatically on
  completion. A `ride.updated` for the *next* ride that arrives while the terminal trip is still on
  screen is therefore discarded, so the driver silently misses the new ride's broadcasts.
- **#2:** `RideState.lastLocation` is set from `WsEventType.location`
  (`ride_state_notifier.dart:17,32,39,75-76`) but has no consumer — the server pushes
  `driver.location` only to the rider. `clearLocation` exists solely to reset it.

## Work

1. **Bug #12:** make the id != update guard *terminal-aware*. When the held ride's status is
   terminal (`completed`/`cancelled`), do **not** early-return; instead adopt the update as a fresh
   ride — `update.applyTo(held.id == update.rideId ? held : null)` — so a pending/accepted update
   for a new ride replaces the finished one. Add a small `bool _isTerminal(String status)` helper
   (or a `Ride.isTerminal` getter in `shared/lib/src/models/ride.dart`; additive) rather than
   duplicating the status strings.
2. Keep the guard for the non-terminal case: a late patch for a *previous* in-progress ride must
   still not swap out the ride the screen is driving.
3. **Bug #2:** delete `RideState.lastLocation` and the `clearLocation` flag/param from
   `copyWith`, drop the `WsEventType.location` case body to a no-op (`break;` — keep the enum, the
   shared socket still emits it, and `websocket_service_test.dart:117` asserts the raw mapping),
   and simplify `clearRide()` to `state.copyWith(clearRide: true)`.
4. Tests (`ride_state_notifier_test.dart`):
   - **#12:** a `ride.updated` for a new ride arriving while `currentRide` holds a *completed* ride
     adopts the new ride; while it holds an *in_progress* ride, the same event is still ignored.
   - **#2:** remove the `lastLocation` assertions (`:136-141,159-168`); assert a `location` event is
     a no-op that leaves `currentRide`/offer untouched.

## Tests

- State-machine tests for both the terminal-replacement and the still-ignored in-progress case;
  updated cleanup tests.

## Accept

- A new ride's `ride.updated` is no longer dropped while the previous trip sits terminal on screen.
- An in-progress held ride is still shielded from a stale previous-ride patch.
- `lastLocation` plumbing is gone; `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
