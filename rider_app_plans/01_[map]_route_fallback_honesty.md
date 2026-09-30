---
tag: map
depends_on: ["[errors]_route_outage_contract_test.md"]
status: open
---

# Rider route fallback honesty + API error surfacing

Stop the rider home screen from presenting a straight pickup→dropoff line as if it were a
road-following route, and surface the backend's error text instead of swallowing it. Mirrors the
pattern the driver app already uses (`driver_app/lib/features/trip/presentation/trip_screen.dart:283-302`).
The API side is already correct (outage → `500`, out-of-coverage → `200` + `is_estimate`); a
regression test for that contract lives in `api_plans/[errors]_route_outage_contract_test.md`.

**Read first:**

- `rider_app/lib/features/home/data/home_provider.dart:77-135` — `NavigationRoute` drops
  `is_estimate`; `navigationRouteProvider` is a `FutureProvider.family`.
- `rider_app/lib/features/home/presentation/home_screen.dart:141-166` — `routeAsync.when(error:
  (_, _) => Polyline(...))` draws a **solid blue width-4** line (identical to `data:`) on every
  error; `_buildRouteInfo` at `:377-398`.
- `driver_app/lib/features/trip/presentation/trip_screen.dart:283-302` — the reference: grey
  **dashed** fallback, solid blue only for a real road route; `:580-585` prefixes `"Estimated "`.
- `shared/lib/src/api/api_exceptions.dart:31` — `apiErrorMessage(error, fallback)` (re-exported by
  `rider_app/lib/core/api/api_exceptions.dart`).

## Gap (verified)

1. `NavigationRoute.fromJson` (`:88-97`) parses only `polyline`/`total_distance_m`/
   `total_duration_s`; `is_estimate` is discarded, so the UI cannot tell a 200-estimate from a
   road route.
2. The `error:` branch (`:157-164`) discards the exception and draws a confident road-less line
   on **every** error status. A correctly-classified 5xx still renders as a fake route.
3. No error text is shown anywhere on failure — `_buildRouteInfo` returns `SizedBox.shrink()`
   when `valueOrNull` is null.
4. The rider app is otherwise the only consumer of `navigationRouteProvider`; the driver has its
   own route cache and is unaffected by this plan.

## Work

1. `home_provider.dart`: add `final bool isEstimate;` to `NavigationRoute` and parse
   `json['is_estimate'] == true` in `fromJson`.
2. `home_screen.dart` — **rendering**: mirror the driver. Build the polylines so a grey
   `StrokePattern.dashed(segments: [12, 8])` straight line is drawn whenever there is no real
   road route (`error`, `loading`, `route.isEstimate`, or `< 2` points), and the solid blue road
   polyline is drawn **only** for a non-estimate `data` result. `_buildRouteInfo` prefixes
   `"Estimated "` when `route.isEstimate`.
3. `home_screen.dart` — **error surfacing**: when `routeAsync.hasError && route == null`, render
   an `Icons.error_outline` row with `apiErrorMessage(routeAsync.error!, 'Route unavailable')`
   and a **Retry** `TextButton` calling `ref.invalidate(navigationRouteProvider(routeArgs))`
   (thread the callback through `_buildBottomSheet` → the route-info/error widget). Error text is
   shown only on the initial failure so a stale successful route is not covered by a transient
   refresh error.
4. Tests (`rider_app/test/features/home/presentation/home_screen_test.dart`, plus a model case):
   - `200` + `is_estimate:false` → solid blue polyline present;
   - `200` + `is_estimate:true` → dashed only, no solid blue, `"Estimated"` text;
   - `500` and a transport `DioException` → dashed fallback **and** the mapped message visible +
     Retry present;
   - `422` → dashed fallback + mapped `error.message` visible (pins that a 4xx is surfaced, not
     disguised).

## Tests

- Widget tests above; a `NavigationRoute.fromJson` case for `is_estimate` true/false.

## Accept

- A failed or estimated route is drawn dashed grey, never as a solid blue road route.
- A route failure shows the backend's `error.message` and offers Retry.
- `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
