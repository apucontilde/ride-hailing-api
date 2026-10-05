---
tag: map
depends_on: []
status: open
---

# [map] Home route preview: failure honesty (never a straight line on an outage)

## Current state (verified 2026-10-04)

`rider_app/lib/features/home/presentation/home_screen.dart` is the **Home route preview** — the
`/home` section mounted inside `RiderShell` (`core/router/app_router.dart:56-86`); it is **not**
the active-trip flow (`/driver-matching` and `/active-ride` live outside the shell,
`app_router.dart:87-105`). Its preview comes from `navigationRouteProvider`
(`features/home/data/home_provider.dart:131-144`) in the `PolylineLayer`:

- `data` branch — `home_screen.dart:137-161`. Builds a client-side straight segment and sets
  `useFallback = route.polyline.length < 2 || route.isEstimate`. On `isEstimate` it draws the
  **client's straight line** (discarding the API's estimate geometry); solid blue is drawn only
  for `!useFallback`.
- `loading` branch — `:162-178`. Draws the client straight line grey-dashed.
- `error` branch — `:179-195`. `error: (_, _)` **discards the exception** and draws the client
  straight line grey-dashed for *every* error status (4xx and 5xx alike).
- `_buildRouteInfo` — `:440-474`. Surfaces `apiErrorMessage` + Retry only when
  `routeAsync.hasError && route == null`; the `is_estimate` label prefix is at `:480`.

**Correction to the original claim** (rider STATUS bug #2; `api_plans/STATUS.md` bug #3 cites the
old `:157`): the line is **not** solid/confident and the error is **not** silent — it is grey
dashed and the message/Retry are surfaced. What is still unfaithful:

1. The `error` path still draws a straight line on every status instead of **nothing**, unlike
   the active trip, where a failed route draws no polyline at all
   (`active_ride_screen.dart:420-439`).
2. The `isEstimate` path draws a **client-synthesized** straight line instead of the API's
   estimate geometry, which the active trip keeps and dashes
   (`trip_route_provider.dart:198-206`; `active_ride_screen.dart:428-437`).
3. A non-estimate response with `<2` points silently becomes the straight fallback rather than
   "unavailable".
4. A failed **refresh** with a retained previous value makes `when(error:)` replace the road
   route with the straight line while `_buildRouteInfo` still shows the stale distance/time
   (`route != null`, so no error row) — the map and the numbers disagree.

## Scope

Make the Home preview as honest as the active-trip flow. Reuse the `[ontrip]` pattern —
`trip_route_provider.dart:21` `TripRouteStatus{idle,loading,ready,estimate,unavailable}` and the
rendering/banner at `active_ride_screen.dart:420-466` — rather than inventing a second contract:

- Derive a preview status from the `AsyncValue` + `NavigationRoute`:
  - `ready` (`isEstimate == false`, `polyline.length >= 2`) → solid blue, **API geometry**.
  - `estimate` (`isEstimate == true`) → grey dashed, **API geometry**, `"Estimated "` label.
    Never the client straight line.
  - `unavailable` (`AsyncError`, or a malformed / `<2`-point non-estimate body) → **no polyline
    at all**; keep/extend the `apiErrorMessage` + Retry row.
  - `loading` → draw nothing (a route-shaped placeholder is exactly what currently implies a
    route); choose the loading affordance in `_buildRouteInfo` or a small progress row.
- Stop the `error: (_, _)` branch from synthesizing geometry; it may still read the exception
  for the message via `apiErrorMessage`.
- Decide the stale-refresh behavior: retain the previous **road** route and surface the error
  (banner or inline) instead of swapping in a straight line; keep the info row consistent with
  what the map draws.
- Update `rider_app/test/features/home/presentation/home_screen_test.dart:71-90` — the current
  test only asserts the screen mounts. Its comment claims (c) 500 and (d) 422 → dashed fallback;
  replace those with "no straight line + error text + Retry", and add an estimate case asserting
  the **API** geometry is drawn dashed. Provider-level `is_estimate` parsing is already covered
  in `home_provider_test.dart`.

## Invariants carried in

- **The active trip never draws a confident road-less route; extend this to the Home preview**:
  an outage must yield no route line (`rider_app_plans/STATUS.md` → Invariants).
- The API never answers an outage with 4xx; it answers outages as 5xx or `200 is_estimate:true`
  (`STATUS.md` → Invariants:215-216).
- An estimate is **explicitly labeled**, never drawn as a road route
  (`trip_route_provider.dart:64-68`).

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Add widget/provider cases: 200 estimate → dashed **API** geometry + "Estimated "; 200 ready →
solid; 500 → no polyline + message + Retry; 422 → no polyline + message + Retry; failed refresh
→ previous road route retained (or error banner), never a straight swap.

## Cross-domain notes

- No open `api_plans/` prerequisite — the routing error/estimate contract is landed.
- Drift for `api-planner` to reconcile: `api_plans/STATUS.md` bug #3 still cites
  `rider_app/lib/features/home/presentation/home_screen.dart:157` and says the app "draws a
  straight line … silently". The client is now grey-dashed and surfaced
  (`home_screen.dart:179-195`, `:440-474`); the remaining API obligation is only to keep outages
  5xx / `is_estimate`.
