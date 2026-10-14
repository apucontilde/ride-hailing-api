---
tag: trip
depends_on: ["[auth]_web_reload_session_bootstrap.md", "landed [trip] launch restore via GET /driver/rides/current (driver_app_plans/STATUS.md → Landed [trip])"]
status: open
---

# 01 [trip] Post-auth live trip restore on every entry path

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification). A real web reload parked on `/#/trip` is **UNVERIFIABLE in this WSL tree**;
> the headless bootstrap + widget probes are the proxy (closing steps under Verification).
>
> **Numbered `01_`** because `depends_on` names the **open** chain head
> `[auth]_web_reload_session_bootstrap.md` (`.opencode/skills/plan-management/SKILL.md`). **Nothing
> here is claimed landed.**

## Goal

After login / launch / web reload, an authenticated driver who has an in-progress trip must be
restored onto that trip **no matter which route the app booted on**. Today the restore only runs when
`HomeScreen` mounts, so a web reload parked on `/#/trip` (or any non-`/home` route) shows "No active
trip" while a real ride is live on the server.

## Verified gap (evidence, not prose)

- Launch restore lives entirely in `HomeScreen.initState` →
  `_restoreActiveTrip()` → `ridesRepository.currentRide()` → `rideStateProvider.notifier.adoptRide`
  — `driver_app/lib/features/home/presentation/home_screen.dart:53,59-69`.
- `TripNotifier` seeds from the **already-held** `rideStateProvider` and then listens for changes —
  `driver_app/lib/features/trip/providers/trip_notifier.dart:119-129`. If nothing adopted a ride
  before `/trip` mounts, the seed is empty and the screen renders the pre-trip state.
- On a web reload of `/#/trip`, `HomeScreen` never mounts (hash reload boots `go_router` at `/trip`;
  see the auth chain head for the URL-strategy evidence), so `_restoreActiveTrip()` never runs and
  `TripNotifier` seeds from an empty `rideStateProvider` → **"No active trip"**.
- The `HomeScreen`-mount restore still works for the cold-start-at-`/home` path; it must not regress.
- `RidesRepository.currentRide()` drops the sibling `stops` — it parses only `data['ride']` —
  `driver_app/lib/features/rides/data/rides_repository.dart:118-124` (same omission in `fetchRide`
  `:91-98`). That is driver bug #24 and is owned by `[ontrip]_itinerary_next_stop.md`; see Decisions.

## API contract (landed — adopt verbatim, no API change)

`GET /api/v1/rides/current` (driver alias `GET /api/v1/driver/rides/current`) returns:

```json
{"ride": <model.Ride>|null, "stops": [<model.RideStop>, ...]}
```

- `ride` is `null` with `stops: []` when the caller has no active ride (a normal 200 the app polls
  for), and a real outage is a 5xx — `internal/handler/ride.go:240-283` (the
  `ErrNotFound` → `{"ride":null,"stops":[]}` branch `:260-264`, the normal `{ride,stops}` branch
  `:270-282`).
- Driver-active statuses are exactly `accepted, driver_arrived, in_progress` — the query already
  excludes `pending` and all terminal states — `internal/repository/ride_repo.go:255-265`.
- Routes: `internal/router/router.go:225` (`/api/v1/driver/rides/current`) and `:250`
  (`/api/v1/rides/current`, role-agnostic `GetCurrentRide`).
- The app already declares the endpoint — `driver_app/lib/core/api/endpoints.dart:28` — and
  `RidesRepository.currentRide()` calls it — `rides_repository.dart:118-124`.
- Adopt the restored ride through the landed `RideStateNotifier.adoptRide(Ride)` —
  `driver_app/lib/core/ride/ride_state_notifier.dart:106-112` (the brief's `:347-354` citation is
  **drift** — the file is 177 lines; `adoptRide` is `:106-112`).

## Recommended design (app-local)

Lift the restore out of `HomeScreen` into the app bootstrap owned by
`[auth]_web_reload_session_bootstrap.md`, so it runs once, after auth resolves, on every entry path:

1. **Bootstrap restore** (extends the auth chain head's bootstrap): after `checkAuth()` resolves and
   the state is an authenticated driver, call `RidesRepository.currentRide()` and, when non-null,
   `adoptRide(ride)`. Non-fatal: a failed/empty restore leaves the app booting normally.
2. **Route the driver onto `/trip` when a live trip was restored.** Prefer a one-shot decision over a
   persistent redirect (a persistent "active ride ⇒ `/trip`" rule would trap the driver and fight
   the `/trip` `PopScope`, `trip_screen.dart:186-191`). Recommended: the bootstrap sets
   `initialLocation` to `/trip` when a non-null ride was restored **and** the platform supplied no
   route; for a hash reload parked on some **other** authenticated route, a one-shot post-bootstrap
   `context.go('/trip')` (guarded by a consumed latch) pushes the driver onto the trip exactly once.
   Deep-linking directly to `/#/trip` needs no push — step 1 already populated `rideState`, so the
   already-mounted `TripScreen` renders the live trip.
3. **Keep `HomeScreen`'s `_restoreActiveTrip()`** as the fallback for a Home-mounted boot, or reduce
   it to a no-op guarded by the same "restored once" flag so the server is not polled twice. Whichever
   is chosen, the cold-start-at-`/home` restore test must stay green.
4. **No persistent provider is removed.** `adoptRide` is landed and additive.

### Alternatives considered

| Option | How | Tradeoffs |
| --- | --- | --- |
| **A — bootstrap/root restore + one-shot `/trip` (RECOMMENDED)** | Restore after auth; set the initial route or push once. | **+** Fixes `/#/trip`, `/#/home`, and any non-`/home` reload. **+** Single fetch. **−** Touches the same bootstrap as the auth chain head (sequenced by `depends_on`). |
| **B — Home-mount only (status quo)** | Leave the restore in `HomeScreen`. | **−** Does not fix the reported case: a `/#/trip` reload never mounts Home → "No active trip". Rejected. |
| **C — each top-level screen restores on mount** | Call the restore from Profile/Settings/History too. | **−** N fetch sites, N race windows, still misses `/trip` itself; violates a single boot path. Rejected. |
| **D — persistent redirect "active ride ⇒ `/trip`"** | Router `redirect` forces `/trip` whenever a ride is held. | **−** Traps the driver (cannot leave `/trip` to reach Home while the trip is live) and conflicts with the `/trip` `PopScope`. Rejected; use a one-shot latch. |

## Decisions to surface

### D1 — Where the restore runs

- **Recommended:** a bootstrap/root restore step (option A), so a non-`/home` reload restores and
  auto-pushes `/trip`.
- Alternative: keep the Home-mount restore only (option B) — insufficient for the reported case.

### D2 — Parse the sibling `stops` now, or defer?

- **Recommended: defer.** `currentRide()`/`fetchRide()` keep returning `Ride`; this plan needs only
  `ride`. The `stops` sibling is **driver bug #24**, owned by `[ontrip]_itinerary_next_stop.md`
  (`rides_repository.dart:91-98,118-124`). Parsing it here would duplicate that plan's
  `RideItinerary`/`RideStop` design and create a merge conflict. When `[ontrip]_itinerary_next_stop.md`
  lands, it changes the restore call site; land them in either order and re-run both suites after both.
- Alternative: parse `stops` now and feed `TripNotifier` — rejected as duplication; coordinate.

### D3 — Which statuses auto-push `/trip`?

- **Recommended: any non-null `ride` from the endpoint.** The server already scopes
  `FindCurrentRideByDriver` to `accepted, driver_arrived, in_progress`
  (`internal/repository/ride_repo.go:255-265`), so "non-null" is exactly the active set and `pending`
  / terminal can never appear. No client-side status filter is needed — filtering again would only
  risk dropping a legitimate restore if the server set ever widens.
- Alternative: an explicit client allow-list — rejected as a second source of truth for the same set.

## Tests to add/change

- `driver_app/test/features/home/presentation/home_screen_test.dart:150-176` — keep "a ride restored
  on launch opens the trip" green (Home-mount fallback). Adjust only if the restore moves fully into
  the bootstrap.
- `driver_app/test/features/trip/providers/trip_notifier_test.dart` — add: `TripNotifier` seeded from
  a `rideStateProvider` already holding a restored `accepted`/`in_progress` ride maps to
  `enrouteToPickup`/`driving` (the seed path `trip_notifier.dart:124-125`).
- `driver_app/test/core/router/app_router_test.dart` (extend) — boot on a **non-splash** route with a
  stubbed `GET /driver/rides/current` returning an active ride; assert `adoptRide` ran,
  `rideState.currentRide.id` is set, and the app is on `/trip` (not `/login`, not "No active trip").
- New bootstrap test (alongside the auth chain head's suite) — active ride ⇒ one
  `GET /driver/rides/current` ⇒ `/trip`; no ride ⇒ normal landing, no push.
- `driver_app/test/features/rides/data/rides_repository_test.dart:65-100` — unchanged (still asserts
  `currentRide()` parses `ride` and returns `null` for `{"ride":null}`).

## Cross-domain

- **No API change.** `GET /api/v1/rides/current` and the driver alias are landed; adopt the shape
  verbatim. If the payload is ever found inconsistent, report it to the cross-app-planner — do not
  edit `api_plans/`.
- **No `shared/` change.** `adoptRide` is landed in `driver_app`.
- `[ontrip]_itinerary_next_stop.md` (open, same domain) owns the `stops` parse (D2) and touches the
  same `rides_repository.dart` read methods; coordinate ordering and re-run both suites after both.
- Depends on the auth chain head `[auth]_web_reload_session_bootstrap.md` for the bootstrap seam and
  for the resolved-auth timing that makes a post-auth restore correct.

## Open inputs / unknowns

| # | Unknown | Resolution |
| --- | --- | --- |
| 1 | One-shot `initialLocation` vs a consumed-latch post-frame `go('/trip')` | Both fix the reported case; `initialLocation` alone does not help a hash reload parked on a different route. Confirm the bootstrap shape with the auth chain head. |
| 2 | Land D2 (stops) before or after `[ontrip]_itinerary_next_stop.md` | Deferred to that plan; land either order, re-run both suites. |
| 3 | Whether `HomeScreen` keeps its own restore as a fallback or delegates fully to the bootstrap | Recommended: delegate, with a shared "restored once" guard so the endpoint is polled once. |

## Dangling-`depends_on` check

`depends_on` names the **open** driver chain head `[auth]_web_reload_session_bootstrap.md` (created in
this batch) — the reason for the `01_` prefix — plus landed `[trip]` restore capability. No dangling
target. The `[ontrip]_itinerary_next_stop.md` coordination is prose, not a `depends_on` entry.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

On a web host (`flutter run -d chrome`, Windows SDK UNC-mapped per AGENTS.md): accept a ride, park the
browser on `/#/trip`, reload, and confirm the live trip is restored (not "No active trip"); then park
on `/#/profile` with a live trip, reload, and confirm the driver is returned to `/trip`; then complete
the trip and confirm a reload lands on `/home` with no forced `/trip`. **UNVERIFIABLE in this WSL
tree.**
