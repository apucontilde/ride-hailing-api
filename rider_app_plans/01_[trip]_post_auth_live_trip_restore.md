---
tag: trip
depends_on:
  - "[auth]_web_reload_session_bootstrap.md"
status: open
---

# 01 [trip] Post-auth live-trip restore (login · reload · reload-at-any-route)

> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> Verification). **Numbered `01_`** because `depends_on` names an **open** plan —
> `rider_app_plans/[auth]_web_reload_session_bootstrap.md` (the unnumbered `[auth]` chain head).
> This is stage 01 of the `auth → trip` restore chain. **Nothing here is claimed landed.**
>
> **Sibling, not a duplicate:** this plan owns the *restore decision* (which route after auth).
> `[ontrip]_active_trip_itinerary.md`, `[ontrip]_status_labels.md` and
> `[ontrip]_driver_arrival_eta.md` own the surfaces the restored trip then renders.

## Request (verbatim)

> on login rider and driver app restore inprogress trip.

## The rider gap (recon, code-confirmed)

There is exactly **one** restore trigger today, and it is coupled to the splash route:

- `SplashScreen._checkAuth()` is the only caller of `currentRideProvider.checkOnce()` and the only
  place that maps `needsRestore` → `/active-ride` —
  `rider_app/lib/features/auth/presentation/splash_screen.dart:21-37`.
- A **fresh login** never checks for a current ride: `_submit` goes straight to `/home` —
  `rider_app/lib/features/auth/presentation/login_screen.dart:89-93`.
- A **web reload** skips the splash entirely (the `[auth]_web_reload_session_bootstrap.md` bug), so
  the restore trigger is never reached.
- `_deriveState` **excludes `pending`** from `needsRestore` (`accepted`/`driver_arrived`/`in_progress`/
  `completed` only) — `rider_app/lib/features/home/data/current_ride_provider.dart:143-149`; a matched-
  but-not-yet-accepted ride would fall through to `/home`.
- `RideStatusNotifier.restore()` has **no callers** — it is dead code —
  `rider_app/lib/features/home/data/ride_status_provider.dart:179-183` (grep-verified: the only match
  is the definition).

## API contract it adopts (landed — verbatim, no API change)

`GET /api/v1/rides/current` → `200 {"ride": <model.Ride> | null, "stops": [RideStop, ...]}` where
`stops` is **always an array** (never null; `[]` when there is no current ride). A rider's active
statuses are **`pending, accepted, driver_arrived, in_progress`** — the query filters to exactly
those, so `completed`/`cancelled`/`no_driver_available` are **never** returned.

Evidence: handler `internal/handler/ride.go:240-283` (null branch `:260-265`; stops always `[]`
`:270-282`); rider query `internal/repository/ride_repo.go:243-253`; driver query `:255-265`.
The rider endpoint constant is already wired — `rider_app/lib/core/api/endpoints.dart:14`
(`currentRide`), consumed at `current_ride_provider.dart:106`.

**Consequence:** "restore a completed ride to show its receipt" is **not reachable** from
`/rides/current`. The `completed` case currently listed in `_deriveState`'s `restore` set
(`current_ride_provider.dart:149`) is therefore **dead** for this endpoint (plan↔code drift — report).

## Decisions to lock (recommendation first)

### D1 — `pending` lands on the matching screen, not `/active-ride`

`pending` maps to `RideStatus.matching` (`ride_status_provider.dart:160-161`) and there is a dedicated
`DriverMatchingScreen` (`rider_app/lib/features/home/presentation/driver_matching_screen.dart`) whose
job is exactly this state (it polls `currentRideProvider` `:36-39` and auto-advances to `/active-ride`
on `driverApproaching` `:109-137`). Sending a `pending` ride to `/active-ride` would show a driver
sheet with no driver.

**Recommendation:** route by status — `pending` → `/driver-matching`;
`accepted`/`driver_arrived`/`in_progress` → `/active-ride`; no ride → `/home`.

### D2 — The restore trigger seam: one bootstrap, not two

Extend the `[auth]_web_reload_session_bootstrap.md` bootstrap from "authenticate" to
**"authenticate → restore ride → choose route"**, so login, cold start, web reload and
reload-at-any-route all converge on one decision point. Concretely: after
`await authProvider.notifier.checkAuth()`, on an authenticated session
`await currentRideProvider.notifier.checkOnce()`, then route per D1.

**Recommendation:** the `[auth]` bootstrap owns the sequencing; this plan owns the *decision function*
and the `pending` fix. Factor a pure, testable helper
`Route resolvePostAuthRoute(AuthState auth, CurrentRideState ride)` (e.g. in
`rider_app/lib/features/auth/...` or `core/router/`) used by both the bootstrap and `LoginScreen._submit`.

### D3 — Restore targets: active statuses only

- `pending` / `accepted` / `driver_arrived` / `in_progress` → restore (D1).
- `cancelled` / `no_driver_available` → **never** restore; go to `/home` (the existing poll already
  turns a vanished tracked ride into `no_driver_available`, `current_ride_provider.dart:126-135`).
- `completed` → **not a restore target via `/rides/current`** (the API never returns it — see above).
  Remove it from `_deriveState`'s restore set and document that a receipt-after-completion restore
  needs a different source (a completed-ride read, e.g. the landed `[tracking]`
  `GET /rides/:id` + receipt) and is **out of scope** here — open a separate `[history]`/`[tracking]`
  plan if the product wants it.

**Recommendation:** D3 exactly as above.

### D4 — The dead `restore()` seam: delete, do not revive

`RideStatusNotifier.restore()` (`ride_status_provider.dart:179-183`) has no callers, duplicates
`_statusFromBackend`, and **constructs a fresh `RideState`** that wipes `driver`/`driverLocation`/
`etaSeconds`/`fare` — a second, lossy source of truth. The converged path already exists:
`currentRideProvider.pollNow()` → `updateFromCurrentRide()` → `_handleRideUpdated()`
(`current_ride_provider.dart:109-110`; `ride_status_provider.dart:115-120`).

**Recommendation: delete `restore()`.** If a reviewer insists on keeping a public method, it must
**delegate** to `updateFromCurrentRide`/`applyRideDetail` rather than construct a bare state.

## Recommended design

1. **`current_ride_provider.dart`** — make the restore decision status-aware: keep `needsRestore`
   (or replace it with the route helper) so `pending` counts, and drop the unreachable `completed`
   from the set (`:143-149`). The `status`/`rideId` are already on `CurrentRideState` (`:11-18`), so
   the helper can read them without a new field (recommended) — add a field only if the route cannot
   be derived purely.
2. **`[auth]` bootstrap** — after a resolved authenticated `checkAuth()`, call `checkOnce()`; route
   via `resolvePostAuthRoute` (D1/D2). Cover reload-at-any-route: an active ride **wins** over the
   deep-linked route (surface this decision — Open inputs #5).
3. **`login_screen.dart:89-93`** — replace the hardcoded `context.go('/home')` with the same
   `checkOnce()` + `resolvePostAuthRoute` decision, so a fresh login restores an in-progress trip.
   Consider a brief loading state while `checkOnce()` runs (Open inputs #6).
4. **`ride_status_provider.dart`** — delete the dead `restore()` (D4).

## Boundaries / cross-domain

- **No API change** — `GET /rides/current` already returns the ride + stops for exactly the active
  statuses.
- **No `shared/` change** — the helper and provider wiring are app-local; no new shared symbol / shim.
- **Driver half is a mirror (report, do not author):** the driver app has the same missing
  login/reload restore; `driver-planner` owns
  `driver_app/lib/features/auth/presentation/splash_screen.dart` and the driver `/trip` restore path.
  The API `/rides/current` driver query (`internal/repository/ride_repo.go:255-265`) already supports
  it.

## Tests (new / changed)

| Test | File | Asserts |
| --- | --- | --- |
| Status-aware restore decision | `rider_app/test/features/home/data/current_ride_provider_test.dart` (extend) | `pending` ⇒ restore with `/driver-matching`; `accepted`/`driver_arrived`/`in_progress` ⇒ `/active-ride`; `null` after a tracked ride ⇒ `no_driver_available`, no restore; `completed` is not produced by `/rides/current` (use the null/empty body). |
| Route helper | new `resolvePostAuthRoute` unit test | pure mapping over `AuthState`×`CurrentRideState` for every status incl. stale/partial. |
| Post-login restore | `rider_app/test/features/auth/presentation/login_screen_test.dart` (extend) | a successful login whose `/rides/current` returns an active ride lands on the trip/matching screen, not `/home`; no active ride lands on `/home`. |
| Reload restore | the `[auth]` bootstrap/router suite (`rider_app/test/core/router/app_router_test.dart` there) | a reload with a stored session **and** an active ride lands on the trip/matching screen. |
| Splash regression | `rider_app/test/features/auth/presentation/splash_screen_test.dart` (extend) | authenticated + active ride ⇒ `ActiveRideScreen`; authenticated + pending ⇒ `DriverMatchingScreen`; authenticated + no ride ⇒ `HomeScreen`. |
| Dead seam removed | `rider_app/test/features/home/data/ride_status_provider_test.dart` (extend) | no `restore()` reference remains (compile-level); `updateFromCurrentRide` remains the single merge path and preserves driver/eta/fare. |

Existing tests that must stay green / be updated (not deleted):
`rider_app/test/features/home/presentation/driver_matching_screen_test.dart`,
`rider_app/test/features/home/presentation/active_ride_screen_test.dart`,
`rider_app/test/features/home/data/current_ride_provider_test.dart:62-99`.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` must be clean; `melos run test` green across rider / driver / shared.
- **UNVERIFIABLE in this WSL harness:** the real reload/login-with-live-ride scenario end to end.
  Close on an on-host browser + a live ride:
  1. start a ride and match a driver (or seed an `accepted` ride via the driver flow);
  2. reload `/#/home` → app restores to `/active-ride`/`/driver-matching`;
  3. log out, log back in while the ride is still active → restores to the trip;
  4. reload while on `/profile` with an active ride → the restore wins (per Open inputs #5).
- `make flutter-analyze` / `make flutter-test` are **broken from this WSL tree** — do not use them.

## Open inputs / unknowns

1. **D1 confirm:** `pending` → `/driver-matching` (recommended) — or a dedicated "searching" state on
   `/active-ride`?
2. **D2 confirm:** fold the restore into the `[auth]` bootstrap (recommended) vs a second trigger in
   `LoginScreen` only.
3. **D3 confirm:** `completed` is not restored (recommended, because `/rides/current` cannot return
   it). If a receipt-after-completion restore is wanted, confirm it as a **separate** plan.
4. **D4 confirm:** delete `restore()` (recommended) vs delegate.
5. **Reload at an arbitrary route:** with an active ride, force the trip/matching route (recommended)
   or honor the deep link and only restore on the trip routes?
6. **Login latency:** is a short "restoring…" state acceptable while `checkOnce()` runs on the
   post-login path?

## Invariants touched (from STATUS.md)

- No polyline / ETA honesty rules are changed here; the restored trip renders under the existing
  `[ontrip]`/`[tracking]` contracts.
- Keep the re-export-shim structure intact; add **no** shared symbol / shim.
- Don't remove public providers used by other screens; the recommendation removes only the
  caller-less `restore()` (all other public providers are extended, not removed).
- The API never answers an outage with 4xx: a failed `checkOnce()` must degrade to `/home`, never to
  a fabricated restore (the poll already surfaces `error` without a fake ride).
