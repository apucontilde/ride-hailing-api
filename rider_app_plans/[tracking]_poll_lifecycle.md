---
tag: tracking
depends_on: []
status: open
---

# Current-ride poll lifecycle: self-stop on terminal states (bug #8)

Bug **#8** of `rider_app_plans/STATUS.md`: the 5 s `GET /rides/current` poll only self-stops on
`no_driver_available` (`current_ride_provider.dart:102`); stopping on cancel/complete is left to the
*screen* calling `stopPolling()`. `active_ride_screen.dart` never calls it — its cancel path
(`:75-89`) and completion dialog (`:266-290`) just `context.go('/home')` — so a cancelled/completed
ride leaves the timer firing for up to `maxAttempts` (60 × 5 s ≈ 5 min). Make the provider own its
own lifecycle.

**Decision (2026-09-29):** the provider self-stops on **any terminal status**
(`no_driver_available`, `cancelled`, `completed`). Screen-side `stopPolling()` calls stay as
belt-and-braces.

**Read first:**

- `rider_app/lib/features/home/data/current_ride_provider.dart:89-148` — `pollNow` (the sole
  self-stop at `:102`) and `_deriveState`.
- `rider_app/lib/features/home/presentation/active_ride_screen.dart:50-106,266-290` — cancel /
  complete paths, neither of which stops the poll.
- `rider_app/lib/features/home/presentation/driver_matching_screen.dart:31-110` — the screen-side
  `stopPolling()` calls this plan leaves in place.
- `rider_app/test/features/home/data/current_ride_provider_test.dart` — the suite to extend
  (injected `now:` clock pattern, `DioAdapter` reply callback).

## Gap (verified)

1. `pollNow` stops only when `state.noDriverAvailable` (`:102`). `_deriveState` (`:113-148`) maps
   `cancelled` / `completed` to plain statuses with no stop signal, so the periodic timer keeps
   firing.
2. Terminal consumers don't compensate: `active_ride_screen` has no `stopPolling()` (and no
   current-ride notifier reference) at all; `driver_matching_screen` stops it only while that screen
   stays mounted.
3. The poll correctly *discovers* a completion/cancel that arrived with no WS event; the bug is that
   it keeps polling after it has.

## Work

1. `current_ride_provider.dart`: add a private terminal predicate
   (`bool _isTerminalStatus(String? s) => s == 'no_driver_available' || s == 'cancelled' ||
   s == 'completed';`) and, in `pollNow` after `_deriveState`, `stopPolling()` when either
   `state.noDriverAvailable` or `_isTerminalStatus(state.status)` is true (replaces the lone
   `if (state.noDriverAvailable)` at `:102`).
2. Leave the `ride == null` handling unchanged: after a previously-seen `rideId` it still yields
   `no_driver_available` (which now stops); before any ride it keeps searching.
3. Add a test-observability getter `@visibleForTesting bool get isPolling => _timer != null;` (no
   behavior change) so tests can assert the timer cancelled without a wall-clock delay.
4. `stopPolling()` is already idempotent — no screen changes, no new public API beyond that getter.

## Tests — `rider_app/test/features/home/data/current_ride_provider_test.dart`

- `cancelled` from `GET /rides/current` → `startPolling()` then `pollNow()` → `isPolling` is false.
- `completed` → same self-stop.
- `no_driver_available` → same self-stop (pins the existing behavior with the new predicate).
- `accepted` / `in_progress` / `pending` → `isPolling` stays true after a poll (regression guard).

## Accept

- After a cancelled / completed / no-driver outcome, no further `GET /rides/current` calls are made,
  even when no screen calls `stopPolling()`.
- `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
