---
tag: trip
depends_on: ["[errors]_route_outage_contract_test.md"]
status: open
---

# Driver route error surfacing

The driver trip screen already renders an honest fallback (grey dashed line when the route
request fails or the backend returns `is_estimate`, solid blue only for a real road route —
`driver_app/lib/features/trip/presentation/trip_screen.dart:283-302`). What it does **not** do is
surface *why* the route is missing: `fetchRoute` swallows every error with `catch (_) { return
null; }` (`trip_notifier.dart:265`). This plan only adds the backend's public `error.message` to
the trip state and renders it. No rendering/style change is in scope — the sibling rider fix is
`rider_app_plans/[map]_route_fallback_honesty.md`.

**Read first:**

- `driver_app/lib/features/trip/providers/trip_notifier.dart:61-99` — `TripState` + `copyWith`
  (the `clearRide` flag is the null-clearing pattern to copy).
- `driver_app/lib/features/trip/providers/trip_notifier.dart:207-270` — `fetchRoute`, the
  `catch (_)` that drops the error.
- `driver_app/lib/features/trip/presentation/trip_screen.dart:350-560` — `_StageControls`, where
  the route summary is rendered (`:502-508`).
- `shared/lib/src/api/api_exceptions.dart:31` — `apiErrorMessage(error, fallback)` already
  imported by `trip_notifier.dart` via `package:ride_hailing_shared/ride_hailing_shared.dart`.

## Gap (verified)

`fetchRoute` catches and discards the exception, returning `null`; no state field carries the
error, and `trip_screen.dart` has nothing to render. A backend `500` with the public message
`"failed to calculate route"` is invisible to the driver.

## Work

1. `trip_notifier.dart`: add `final String? routeError;` to `TripState` and a `clearRouteError`
   flag to `copyWith` (mirroring `clearRide`). In `fetchRoute`, clear it on success and, on
   failure, set `state = state.copyWith(routeError: apiErrorMessage(e, 'Route unavailable'))`
   before returning `null`.
2. `trip_screen.dart`: thread `routeError` into `_StageControls` and render a small
   `Icons.error_outline` + message line (error-colored `bodySmall`) beneath the target/leg
   summary when it is non-null. No Retry button is needed — the position stream re-fetches and a
   success clears the error.
3. Tests:
   - `driver_app/test/features/trip/providers/trip_notifier_test.dart` (`fetchRoute()` group,
     `:517-535`): the existing "returns null on failure" test also asserts `state.routeError` is
     the mapped message; add a success-clears-error case.
   - `driver_app/test/features/trip/presentation/trip_screen_test.dart`: a failed route fetch
     renders the error text.

## Tests

- Provider test for `routeError` set-on-failure / cleared-on-success; widget test for the
  rendered message.

## Accept

- A failed route fetch shows the backend's `error.message` on the trip screen; a later success
  clears it.
- `melos run analyze` / `melos run test` stay green.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```
