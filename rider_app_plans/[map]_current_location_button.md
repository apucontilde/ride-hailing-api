---
tag: map
depends_on: []
status: open
---

# [map] Current-location + route-fit button (rider; canonical shared contract)

> **Owner:** `rider-planner`. **Plan only** — no production code, test, manifest or `melos` run in
> this authoring pass. Verify with `melos run analyze` + `melos run test` (Linux FVM SDK, below).
>
> **Independent chain head, unnumbered.** `depends_on: []` (no open-plan prerequisite), so the
> filename is `[map]_<slug>.md` per the plan-management skill. The driver half is a dependent
> consumer, authored separately as `driver_app_plans/01_[map]_current_location_button.md`
> (`depends_on: ["rider_app_plans/[map]_current_location_button.md"]`); it must adopt the shared
> signatures and the resolved cycle/auto-fit/key semantics in §"Canonical shared contract"
> **verbatim**. This file is the canonical owner of that contract.
>
> **CROSS-DOMAIN.** The two new shared files are rider-authored but consumed by both apps.
> `shared/` may only be **added to** here: no app file moves, no new re-export shims. Both apps
> import the new symbols directly from the barrel
> `package:ride_hailing_shared/ride_hailing_shared.dart`.
>
> **No API/server change is involved.**

## Goal

Every map surface in the **rider** app gets the same bottom-right control and the same shared
state machine:

1. when the route/itinerary first appears (initial mount) or materially changes, the shared widget
   auto-fits the route;
2. a successful auto-fit counts as the fit half of the cycle, so the next press centers on the
   current-location target;
3. presses then alternate **fit route → current location → fit route → …**; a successful action
   advances, a failed action stays on that action (a failed fit retries the fit; a failed locate
   retries the locate).

On Home the locate target is the rider fix. On ActiveRide it is the **driver's** last fix for
`matching`/`driverApproaching`/`driverArrived`/`onTrip`, and the rider fix for other/terminal
statuses. The control and the camera-fit policy live in `shared/` so the rider and driver apps
cannot drift.

## Evidence map (verified in this tree)

| Claim | Evidence |
| --- | --- |
| Home owns a `MapController` | `rider_app/lib/features/home/presentation/home_screen.dart:58` |
| Home's current fit is itinerary-only, `CameraFit.bounds`, panel-aware bottom padding, `maxZoom: 16` | `home_screen.dart:154-190` (points `:155-162`; padding `:174-182`; maxZoom `:183`) |
| Home map renders the API preview polyline, markers and attribution | `home_screen.dart:399-491` (`FlutterMap` `:411`, `preview.polyline` `:423`, marker layer `:438-489`, attribution `:491`) |
| Home's existing bottom-right my-location FAB; today it calls `_initLocation` | `home_screen.dart:515-530` (FAB `:524-528`, `onPressed: _initLocation` `:525`) |
| `_initLocation` is the startup permission/fix path (notice + snackbar UX) | `home_screen.dart:238-271` |
| Itinerary fit after pickup / destination selection | `home_screen.dart:605,633` |
| Itinerary fit after stop add/remove/reorder | `home_screen.dart:223,230,235` |
| Panel height helper used by the fit padding | `home_screen.dart:314` (`_panelPixels`) |
| Persistent location notice data/condition | `home_screen.dart:748-751`; notice widget `:756-811` |
| Home's injectable location seam (permission + fresh fix) | `rider_app/lib/features/home/data/location_service.dart:18,72` |
| Home tests' fake location service / overrides | `rider_app/test/features/home/presentation/home_screen_test.dart:22,124-133` |
| Home test already asserts the FAB sits above the collapsed panel | `rider_app/test/features/home/presentation/home_screen_test.dart:1259-1263` |
| ActiveRide owns a `MapController` and a post-frame `_mapReady` latch | `rider_app/lib/features/home/presentation/active_ride_screen.dart:40,59,81` |
| ActiveRide's rider fix comes from `LocationHelper.getPositionStream` into `_riderPosition` | `active_ride_screen.dart:114-127` |
| ActiveRide watches the trip route | `active_ride_screen.dart:590` |
| ActiveRide's driving-phase locate source is the typed `RideState.driverLocation` | `active_ride_screen.dart:605,661-666` |
| ActiveRide auto-recenters on every driver fix (separate from the trip route) | `active_ride_screen.dart:604-611` (`ref.listen<DriverLocation?>` → `_centerOnDriver`), `:423-431` (`_centerOnDriver`) |
| 200 m driver refetch / `fetchedAt` are not material route changes | `driver_app/lib/features/trip/presentation/trip_screen.dart:59`; `driver_app/lib/features/trip/providers/trip_notifier.dart:49,150,424` |
| ActiveRide map: `FlutterMap`, trip polyline, itinerary/rider/driver markers | `active_ride_screen.dart:676-750` (polyline `:689-703`, markers `:704-747`) |
| ActiveRide's driver sheet is a bottom `Positioned` + `AppBottomSheet`; there is no location button today | `active_ride_screen.dart:832-933` (`Positioned` `:848`, `AppBottomSheet` `:852`; last Stack child `:767`) |
| Active ride tests build overrides (incl. `mapTileLayerProvider` null) and pump the route | `rider_app/test/features/home/presentation/active_ride_screen_test.dart:364-379,401-409` |
| Shared barrel exports the existing map contract | `shared/lib/ride_hailing_shared.dart:28-30` |
| Existing shared map files/tests | `shared/lib/src/map/map_tile_config.dart`, `map_tile_layer.dart`, `map_tile_attribution.dart`; `shared/test/map/map_tile_config_test.dart`, `map_tile_layer_test.dart` |
| Shared already depends on `flutter_map` 7 / `latlong2` / `mocktail` | `shared/pubspec.yaml:20-21,27` |
| Shared device-fix helper (returns null, never throws out) | `shared/lib/src/utils/location_helper.dart:25` |
| Driver consumer: map controller, `_fitTo`, map in `Expanded`, `_MapView` road points/focus, `lastPositionProvider` | `driver_app/lib/features/trip/presentation/trip_screen.dart:32,79-93,223-233,279-397` (road `:317-322`, focus `:353-366`, provider `:63,154,183`); `driver_app/lib/core/location/location_service.dart:38-58` |

## Locked behavior decisions

1. **Scope.** Every map surface in the **rider** app: Home (`home_screen.dart`) and ActiveRide
   (`active_ride_screen.dart`). Driver Home and the rider `DriverMatchingScreen` have no map — out of
   scope. Driver Trip is the driver plan's scope.
2. **Full press cycle + material-change auto-fit.** The button alternates **fit route → current
   location → fit route → …**. A successful action advances to the other action; a failed action
   stays on that action (a failed fit retries the fit; a failed locate retries the locate). On the
   widget's initial mount, and whenever `routeKey` changes, if `hasRoute` is true the shared
   `AppMapLocateButton` schedules a post-frame `onFitRoute()` call. A successful auto-fit counts as
   the fit phase, so the next press locates; a failed auto-fit leaves the next press on fit (retry).
   `hasRoute: false` never auto-fits and the first press locates. This shared widget is the **single
   cross-app implementation of this decision**; rider and driver screens must not duplicate it.
3. **Placement.** Bottom-right of the visible map. Home keeps its existing
   `Positioned(right: 16, bottom: 16)` + panel `Transform.translate` slot and only swaps in the
   shared widget. ActiveRide's map is full-screen behind the driver info sheet: place the button
   immediately above the sheet, right-aligned, without covering it. Refactor
   `_buildDriverInfoSheet` to return the sheet widget and wrap button + sheet in one bottom
   `Column(mainAxisSize: min)`.
4. **"Route" fit points per screen.**
   - **Home:** the preview `polyline` when it has ≥ 2 points, else the itinerary pins (pickup-or-fix,
     stops, destination). Reuse/extend `_fitItinerary` and its panel-aware bottom padding
     (`:174-182`); it must return whether the fit happened so the cycle can advance.
   - **ActiveRide:** `tripRoute.polyline` when ≥ 2 points, else the itinerary pins (pickup,
     `stopPoints`, dropoff, rider position, driver position).
   - **`routeKey` = material changes only (Option B).**
     - **Home:** a 3-value route discriminator (`none` / `ready` / `estimate`, mirroring the
       driver's contract) + pickup/stops/destination coordinates ONLY. Exclude `_currentPosition`,
       polyline geometry/length and totals. The discriminator is the **last settled** road/estimate
       phase: a transient `loading`/`unavailable` preview (the route-plan family is re-keyed when a
       locate press moves the device-fix origin) keeps the settled value, so
       `ready → loading → ready` is not material. `none → ready` (the road route first arriving)
       auto-fits once; a locate's own fix refresh neither auto-fits nor resets the cycle.
     - **ActiveRide:** trip-route `status.name` + pickup / `stopPoints` / dropoff coordinates ONLY.
       Exclude `_riderPosition`, the driver position, `fetchedAt` and polyline geometry.
     - **Driver consumer (cross-reference only):** next-waypoint coordinates + route status ONLY,
       where status is a 3-value discriminator: none (`route == null`), ready (`!isEstimate`),
       estimate (`isEstimate`). Exclude `fetchedAt`, the driver position and same-endpoint geometry
       changes. `none → ready` (the road route arriving) is a material change and auto-fits once;
       `ready → ready` refreshes and same-endpoint reroutes are not. The driver plan will be updated
       separately.
     - Therefore a silent 30 s `trip_route_provider` refresh
       (`trip_route_provider.dart:68,87,114`) or a 200 m driver refetch
       (`trip_notifier.dart:49,150,424`) does **not** auto-fit or reset the cycle; a traffic reroute
       with identical waypoints does not count either.
5. **Current-location target.**
   - **Home:** rider fix only. Preserve the existing permission UX. On a locate press, re-resolve
     availability (the notice/snackbar path at `:238-271`) and fetch a fresh fix; fall back to the
     cached `_currentPosition`; update state; then `centerMapCamera`. Never fabricate a location.
     `_initLocation` stays the startup path and must **not** be repurposed into the button handler.
   - **ActiveRide:** status-aware. For `matching`, `driverApproaching`, `driverArrived` and `onTrip`
     the locate target is `RideState.driverLocation` (the driver's last fix). For
     `completed`/`cancelled`/`noDriverAvailable`/`idle` fall back to the rider fix (`_riderPosition`,
     else `LocationHelper.getCurrentPosition()` via the test seam, in a `try/catch`). If a
     driving-phase status has no driver fix yet, return `false`, show a truthful
     `Waiting for driver location…` snackbar via `onLocationUnavailable`, and **do not move the
     camera** (locked; recommended default). If an other-status target has no rider fix, show
     `Waiting for your location…` and do not move.
   - **Driver follow stays exactly as-is on ActiveRide.** `_centerOnDriver`
     (`active_ride_screen.dart:423-431`, listener `:604-611`) is not paused by a locate press; a later
     driver fix still re-centers.
6. **Locate zoom = 16 (confirmed).** Keep the shared `centerMapCamera` default.
7. **No dependency/API change.** `flutter_map`/`latlong2` are already shared dependencies; no new
   package is added.

## CROSS-DOMAIN boundary + canonical shared contract

**CROSS-DOMAIN:** the rider plan owns and authors the shared files below. The driver plan
(`driver_app_plans/01_[map]_current_location_button.md`) is a **consumer only** and must adopt these
signatures plus the resolved cycle/auto-fit/key semantics verbatim; it must not redefine the
contract. Both apps import from the unfiltered barrel — do not mint app shims for these symbols.

### New files (public signatures unchanged)

`shared/lib/src/map/map_camera_fit.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Fits [controller] to [points] with the shared camera-fit policy.
/// Returns `false` when there is nothing to fit (< 2 points) or the camera is
/// not attached yet; callers keep the fit step pending in that case.
/// A duplicate fit whose target is already in place also returns `true`
/// (`fitCamera` answers `false` for that exact no-op).
bool fitMapCamera(
  MapController controller,
  List<LatLng> points, {
  EdgeInsets padding = const EdgeInsets.all(48),
  double maxZoom = 16,
});

/// Centers [controller] on [point] at [zoom].
/// Returns `true` once the camera is at the requested center/zoom, including
/// when it was already there (a repeated locate is not a failure); returns
/// `false` when the camera is not attached or the move was rejected.
bool centerMapCamera(
  MapController controller,
  LatLng point, {
  double zoom = 16,
});
```

`shared/lib/src/map/app_map_locate_button.dart`

```dart
import 'package:flutter/material.dart';

/// The one bottom-right map control shared by the rider and driver apps.
///
/// Presses alternate **fit route → current location → fit route → …**. On the
/// initial mount and whenever [routeKey] changes, if [hasRoute] is true the
/// widget schedules a post-frame [onFitRoute]; a successful auto-fit counts as
/// the fit phase, so the next press locates. A failed action stays on that
/// action and retries; a failed locate calls [onLocationUnavailable].
class AppMapLocateButton extends StatefulWidget {
  const AppMapLocateButton({
    super.key,
    required this.routeKey,
    required this.hasRoute,
    required this.onFitRoute,
    required this.onCurrentLocation,
    this.onLocationUnavailable,
  });

  /// Changes only on a material route/itinerary change; triggers auto-fit and
  /// starts a new cycle.
  final Object? routeKey;

  /// `false` when there is no route/itinerary to fit; no auto-fit occurs and
  /// every press locates.
  final bool hasRoute;

  /// Fits the camera to the drawn route. Return `true` once the camera moved,
  /// so the action advances to the current location.
  final bool Function() onFitRoute;

  /// Resolves the current-location target and centers on it. Return `false`
  /// when no fix or no move was possible; the action stays on locate.
  final Future<bool> Function() onCurrentLocation;

  final VoidCallback? onLocationUnavailable;
}
```

> The public **signatures** above are unchanged from the canonical contract; only the doc comments
> and semantics reflect the resolved full cycle. The implementation adds the private
> `_AppMapLocateButtonState` / `createState` and the two function bodies described in step 1; it does
> not change any signature.

### Barrel

Append to `shared/lib/ride_hailing_shared.dart` (after the existing map exports at `:28-30`):

```dart
export 'src/map/map_camera_fit.dart';
export 'src/map/app_map_locate_button.dart';
```

### Rendering contract for the button

- A `FloatingActionButton` with `Icons.my_location`, `backgroundColor: AppColors.surface`, and icon
  `color: AppColors.info`.
- Its root carries `const Key('map-locate-button')` so both rider screens and the driver tests can
  find it without relying on widget type.
- State-aware tooltip, derived from the cycle state:
  - `Current location` when the next press will locate: `_nextIsLocate` is true (including
    immediately after a successful auto-fit) **or** `hasRoute` is false (there is no route to fit,
    so the press locates);
  - `Fit route` when the next press will fit: `hasRoute` is true and `_nextIsLocate` is false,
    including after a failed auto-fit.
- An in-flight guard (`_locating`) around `onCurrentLocation`, so a double tap cannot stack locate
  calls. A failed locate leaves the cycle on locate (the next press retries locate); a failed fit
  leaves it on fit (the next press retries fit).

## Implementation steps (ordered; exact files/symbols)

### 1. Shared camera + button (CROSS-DOMAIN, rider-owned)

**`shared/lib/src/map/map_camera_fit.dart`** (new):

- `fitMapCamera`: return `false` when `points.length < 2`; build
  `LatLngBounds.fromPoints(points)` and call
  `controller.fitCamera(CameraFit.bounds(bounds: ..., padding: padding, maxZoom: maxZoom))` inside a
  `try/catch`; return `true` on success. A `fitCamera` `false` whose fitted target
  (`cameraFit.fit(controller.camera)`) equals the current camera center/zoom is a duplicate fit and
  still returns `true` (the route is framed); any other false/throw (camera not attached or a
  rejected move) returns `false`.
- `centerMapCamera`: call `controller.move(point, zoom)` inside a `try/catch`; return `true` on
  success. A `move` `false` whose current camera center/zoom already equals the requested
  center/zoom is a repeat locate and still returns `true`; any other false/throw (camera not
  attached or a rejected move) returns `false`.
- No state, no I/O, no app imports.

**`shared/lib/src/map/app_map_locate_button.dart`** (new):

- `_AppMapLocateButtonState` fields: `bool _nextIsLocate = false; bool _locating = false; int
  _autoFitToken = 0;`.
- `initState`: if `widget.hasRoute`, call `_scheduleAutoFit()`.
- `didUpdateWidget`: when `oldWidget.routeKey != widget.routeKey`, set `_nextIsLocate = false` (the
  rebuild is already scheduled) and, if `widget.hasRoute`, call `_scheduleAutoFit()`.
- `_scheduleAutoFit`: bump `_autoFitToken`, then
  `WidgetsBinding.instance.addPostFrameCallback((_) { ... })`. The callback returns if `!mounted`, the
  captured token is stale, or `!widget.hasRoute`; otherwise it calls `widget.onFitRoute()` inside a
  `try/catch` and, when mounted, `setState(() => _nextIsLocate = fitted)`. **This is the single
  cross-app implementation of decision #2** — no screen schedules its own initial/route-change fit.
- `_handlePress` state machine, with `_locating` as the first guard:
  - **next action is fit** (`widget.hasRoute && !_nextIsLocate`): call `onFitRoute()` inside a
    `try/catch`; on `true` set `_nextIsLocate = true` (next press locates); on `false`/throw leave it
    `false` (next press retries fit); return;
  - **next action is locate** (`_nextIsLocate || !widget.hasRoute`): set `_locating = true`;
    `await onCurrentLocation()` inside a `try/catch`; on `true` set `_nextIsLocate = false` (next
    press fits when a route exists); on `false`/throw leave the state unchanged (retry locate) and
    call `onLocationUnavailable`; clear `_locating` in `finally` (guarded by `mounted`).
- `_tooltip`: `(_nextIsLocate || !widget.hasRoute) ? 'Current location' : 'Fit route'`.
- `build`: `FloatingActionButton(key: const Key('map-locate-button'), tooltip: _tooltip, ...)` with
  the rendering contract above; the in-flight guard is behavioral, not a disabled spinner.
- Keep the widget free of app imports; it imports only `package:flutter/material.dart` plus the
  local `../theme/app_colors.dart` for the rendering contract's `AppColors` values.

**`shared/lib/ride_hailing_shared.dart`**: add the two barrel exports above.

### 2. Home (`rider_app/lib/features/home/presentation/home_screen.dart`)

- Extract the fit padding from `_fitItinerary` (`:174-182`) into
  `EdgeInsets _fitPadding()` and change `_fitItinerary` to return `bool`:
  - `_itineraryPoints()` returns pickup-or-fix, stops, destination (the current `:155-162` list).
  - 0 points → `false`; exactly 1 point → `centerMapCamera(_mapController, points.first, zoom: 15)`
    (preserves today's single-pin centering); ≥ 2 → `fitMapCamera(..., padding: _fitPadding(),
    maxZoom: 16)`.
  - Existing call sites (`:223,230,235,605,633,124`) may ignore the return value.
- Add `bool _fitRoute(HomeRoutePreview preview)`: if `preview.polyline.length >= 2`, fit the preview
  polyline with `_fitPadding()`; otherwise delegate to `_fitItinerary()`.
- Add `bool _canFitRoute(HomeRoutePreview preview)`:
  `preview.polyline.length >= 2 || _itineraryPoints().length >= 2`.
- Add `String _homeRouteKey(HomeRoutePreview preview)`: a 3-value route discriminator (`none` /
  `ready` / `estimate`) + pickup/stops/destination coordinates ONLY (the material key in decision
  #4). The discriminator tracks the last **settled** road/estimate phase: `loading`/`unavailable`
  keep the previous value, so the family re-key caused by a locate's own device-fix update
  (`ready → loading → ready`) is not material. Exclude `_currentPosition`, polyline geometry/length
  and totals, so a GPS refresh, a silent preview refresh or a same-endpoint reroute neither
  auto-fits nor resets the cycle; a genuine `none → ready` still auto-fits once.
- Add `Future<bool> _locateCurrentPosition()` (do **not** modify `_initLocation`):
  - `ref.read(locationServiceProvider)`, `requestAvailability()`, set `_locationStatus` (this keeps
    the persistent notice truthful);
  - when granted, `getCurrentPosition()`; on a non-null fix set `_currentPosition` and use it; on
    null fall back to the cached `_currentPosition`;
  - if no target exists, `_showSnackBar(...)` with the same permission/unable wording as
    `_initLocation` (`:238-271`) and return `false`;
  - otherwise `return centerMapCamera(_mapController, target)` (default zoom 16). Never write a
    fabricated point into `_pickupLocation`/`_currentPosition`.
- Replace the FAB child inside the existing `Positioned`/`AnimatedBuilder`/`Transform.translate`
  slot (`:515-530`) with:
  `AppMapLocateButton(routeKey: _homeRouteKey(preview), hasRoute: _canFitRoute(preview),
  onFitRoute: () => _fitRoute(preview), onCurrentLocation: _locateCurrentPosition)`.
  Keep the slot/offsets exactly as they are; Home's own snackbar is the failure surface, so
  `onLocationUnavailable` can stay `null`.
- The shared widget owns the initial-mount and `routeKey`-change auto-fit. Home may keep
  `_fitItinerary` for pin edits; duplicate fits are idempotent. Do not feed a `fetchedAt`/geometry
  key into the button.

### 3. ActiveRide (`rider_app/lib/features/home/presentation/active_ride_screen.dart`)

- Add `final GlobalKey _sheetKey = GlobalKey();` next to `_mapController` (`:40`) and use it on the
  returned `AppBottomSheet` for fit padding measurement.
- Add an app-local, test-overridable fix seam (shared-only rule; this is a provider, not a shim):

  ```dart
  /// One-shot device fix for the locate button fallback. Widget tests override
  /// it so they never touch the geolocator platform channel.
  final riderCurrentPositionProvider =
      Provider<Future<LatLng?> Function()>((ref) => () async {
    final position = await LocationHelper.getCurrentPosition();
    return position == null
        ? null
        : LatLng(position.latitude, position.longitude);
  });
  ```

- Helpers:
  - `List<LatLng> _itineraryPins(TripRouteState route)` → `pickup`, `stopPoints`, `dropoff`.
  - `List<LatLng> _routeFitPoints(TripRouteState route, LatLng? rider, LatLng? driver)` →
    `route.polyline` when `length >= 2`, else `_itineraryPins(route)` plus non-null rider/driver.
  - `bool _canFitRoute(TripRouteState route)` → `route.polyline.length >= 2 ||
    _itineraryPins(route).length >= 2` (moving markers alone are not a route/itinerary).
  - `String _tripRouteKey(TripRouteState route)` → trip-route `status.name` + pickup/`stopPoints`/
    dropoff coordinates ONLY (material key, decision #4). **Exclude** `_riderPosition`, the driver
    position, `fetchedAt` and polyline geometry, so a silent 30 s refresh or a 200 m driver refetch
    neither auto-fits nor resets the cycle.
  - `double _sheetBottomInset()` → measured `_sheetKey` height + 24, fallback ~220 before first
    layout.
  - `bool _fitTripRoute(route, rider, driver)` → `false` when `!_mapReady`, else
    `fitMapCamera(_mapController, _routeFitPoints(...), padding: EdgeInsets.fromLTRB(60, 60, 60,
    _sheetBottomInset()), maxZoom: 16)`.
  - `Future<bool> _locateActiveTarget(RideStatus status)`:
    - for `matching`/`driverApproaching`/`driverArrived`/`onTrip`, read
      `ref.read(rideStatusProvider).driverLocation`; if null return `false` **without moving the
      camera** (the caller surfaces `Waiting for driver location…`); otherwise
      `centerMapCamera(_mapController, LatLng(fix.lat, fix.lng))`;
    - for `completed`/`cancelled`/`noDriverAvailable`/`idle`, use `_riderPosition`; when null,
      `await ref.read(riderCurrentPositionProvider)()` in a `try/catch`, set `_riderPosition` on a
      fix; if still null return `false`; otherwise `centerMapCamera(_mapController, fix)`;
    - `_centerOnDriver` is untouched — driver follow stays on.
- Refactor `_buildDriverInfoSheet` (`:832-933`) to return the `AppBottomSheet` widget (drop its
  `Positioned` wrapper) and put `key: _sheetKey` on that sheet.
- Replace the last `Stack` child (`:767`) with one bottom `Positioned(bottom: 0, left: 0, right: 0)`
  containing:

  ```dart
  Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(right: 16, bottom: 12),
        child: Align(
          alignment: Alignment.centerRight,
          child: AppMapLocateButton(
            routeKey: _tripRouteKey(tripRoute),
            hasRoute: _canFitRoute(tripRoute),
            onFitRoute: () => _fitTripRoute(
              tripRoute,
              _riderPosition,
              driverPosition,
            ),
            onCurrentLocation: () => _locateActiveTarget(rideState.status),
            onLocationUnavailable: () => _showLocationUnavailable(rideState.status),
          ),
        ),
      ),
      _buildDriverInfoSheet(rideState, driverPosition),
    ],
  )
  ```

  `_showLocationUnavailable(RideStatus status)` chooses the truthful
  `SnackBar('Waiting for driver location…')` for `matching`/`driverApproaching`/`driverArrived`/
  `onTrip`, and `SnackBar('Waiting for your location…')` for the other statuses. The button
  therefore sits immediately above the sheet and never covers it; the sheet remains the bottom-most
  widget. The shared widget owns the initial-mount and `routeKey`-change auto-fit; ActiveRide does
  not schedule its own.

## Tests to add/update

### New shared `shared/test/map/map_camera_fit_test.dart`

Use `mocktail` + a `MockMapController extends Mock implements MapController`.

- `fitMapCamera` returns `false` and never calls `fitCamera` for 0/1 points.
- `fitMapCamera` returns `true` and passes the supplied `padding`/`maxZoom` (capture the
  `CameraFit`, cast to `FitBounds`, assert `padding` and `maxZoom`).
- `fitMapCamera` returns `false` when `fitCamera` throws (camera not attached).
- `fitMapCamera` treats a duplicate fit already in place (fitted target == current camera) as
  `true`.
- `centerMapCamera` calls `move(point, zoom)` and returns `true`.
- `centerMapCamera` treats an exact repeat center/zoom already in place as `true`.
- `centerMapCamera` returns `false` when `move` throws or the camera is elsewhere on a rejected
  move.

### New shared `shared/test/map/app_map_locate_button_test.dart`

Pump `AppMapLocateButton` inside a minimal `MaterialApp`/`Scaffold`; tap
`find.byKey(const Key('map-locate-button'))`.

- Auto-fit on initial mount when `hasRoute`: after the post-frame callback `onFitRoute` is called
  once, the tooltip is `Current location`, and the first tap calls `onCurrentLocation` (not a second
  fit).
- Full cycle: locate success → next tap fits; fit success → next tap locates.
- A `routeKey` change auto-fits again (post-frame `onFitRoute`) and the next tap locates.
- Failed auto-fit (`onFitRoute` → `false` on the post-frame call): tooltip `Fit route`; the next tap
  retries fit; on success the next tap locates.
- Failed locate: after a successful auto-fit, `onCurrentLocation` → `false`; the tooltip stays
  `Current location`; the next tap retries locate and `onLocationUnavailable` is called each time.
- `hasRoute: false`: never auto-fits; tooltip `Current location`; every tap locates.
- Double-tap guard: an unresolved `onCurrentLocation` future is invoked once across two taps.
- Icon/colors: `Icons.my_location`, `AppColors.info` on the icon, `AppColors.surface` FAB.

### Rider `rider_app/test/features/home/presentation/home_screen_test.dart`

- Replace/extend the existing FAB-position case (`:1259-1263`) to find
  `find.byKey(const Key('map-locate-button'))` and still assert its bottom edge stays above the
  collapsed `AppBottomSheet`.
- Auto-fit on route load: after `pumpHome(pickup:, destination:)` and a post-frame pump, the map is
  fitted to the route (`visibleBounds` contains pickup/destination) and the tooltip is `Current
  location`. Set `fakeLocation.position` to a fresh rider fix, tap once → `camera.center` ≈ that fix
  at zoom 16; tap again → route fit; tap a third time → rider fix again.
- Route-change auto-fit: add a stop (existing `addStopResult` flow) or re-pick the destination; the
  shared widget auto-fits the new material route after the frame and the next tap locates (tooltip
  `Current location`). Duplicate fits from Home's own pin-edit `_fitItinerary` are idempotent.
- Locate with only a destination (no manual pickup): after the route auto-fit, set a moved fake fix,
  tap locate, flush the post-frame callback and the re-keyed preview fetch, then assert the camera
  center is the new fix at zoom 16 and the tooltip is `Fit route`. This is the regression guard for
  the `ready → loading → ready` family re-key: the transient refresh must not schedule an auto-fit
  over the locate.
- Permission-denied locate press: availability denied; tap locate and assert the truthful
  `Location permission is required to request rides` snackbar, no fix fetch, the camera unchanged,
  and the cycle unchanged.
- No-fix locate: `fakeLocation.position = null`, availability granted; after the route auto-fit, tap
  locate and assert the truthful `Unable to get current location` snackbar and that the camera did
  not move / no point was fabricated.
- Remove/replace any assertion that expected a one-way cycle or a route-key change to leave the
  tooltip on `Fit route`.

### Rider `rider_app/test/features/home/presentation/active_ride_screen_test.dart`

- Button placement: after `pumpRoute`, `tester.getRect(find.byKey(const
  Key('map-locate-button')))` is right-aligned (16 px inset) and its `bottom` is `<=` the
  `AppBottomSheet` top.
- Auto-fit on route load: after `pumpRoute` and a post-frame pump, the trip route is fitted
  (`visibleBounds` contains the trip polyline/pickup+dropoff) and the tooltip is `Current location`.
- Status-aware locate: with a known `RideState.driverLocation`, parameterize the first tap over
  `matching`, `driverApproaching`, `driverArrived` and `onTrip`; each centers on the driver fix at
  zoom 16. For `completed`/`cancelled`/`noDriverAvailable`/`idle`, override
  `riderCurrentPositionProvider` and assert the first tap centers on the rider fix.
- Full cycle: first tap locates (driver or rider target), second tap fits the trip route, third tap
  locates again.
- No driver fix during a driving-phase status (`matching`/`driverApproaching`/`driverArrived`/
  `onTrip`): tap locate → `Waiting for driver location…` snackbar and the camera does not move.
- Follow remains on: after a locate, emit a newer driver fix; the camera re-centers on the new fix
  (`_centerOnDriver` unchanged, no pause flag).
- Remove/replace any old assertions that expected a one-way cycle or a `fetchedAt`-driven reset.

## Out of scope

- **Driver app edits** — the driver plan
  (`driver_app_plans/01_[map]_current_location_button.md`) owns its Home/Trip wiring and is the
  dependent consumer of this contract.
- **API/server edits** — no endpoint, payload or contract changes.
- **Real-device checks** — actual GPS fix acquisition, permission dialogs, Android/iOS map rendering
  and touch behavior are UNVERIFIABLE in this WSL harness (see Verification).
- Driver Home / rider `DriverMatchingScreen` (no map), and any change to the OSM tile host.
- New dependencies, new app shims, or moving app files into `shared/`.

## Open decisions

**None.** All five decisions are resolved and closed.

1. **Full cycle — resolved.** Presses alternate **fit route → current location → fit route → …**;
   a successful action advances, a failed action stays on that action and retries.
2. **Auto-fit on material route change — resolved.** The shared `AppMapLocateButton` auto-fits on
   initial mount and whenever `routeKey` changes when `hasRoute` is true. A successful auto-fit makes
   the next press locate; a failed auto-fit leaves the next press on fit. This is the single
   cross-app implementation; screens do not duplicate it.
3. **Locate zoom — resolved. `16`**, the shared `centerMapCamera` default.
4. **ActiveRide locate target — resolved.** `matching`/`driverApproaching`/`driverArrived`/`onTrip`
   locate the driver's last fix; other/terminal statuses locate the rider fix. A driving-phase status
   with no driver fix yet is **locked** to `Waiting for driver location…`, return `false`, and **no
   camera move** (the recommended default). Driver follow is **not** paused: `_centerOnDriver`
   (`active_ride_screen.dart:604-611,423-431`) stays exactly as-is.
5. **Material-change key only (Option B) — resolved.** Home = a 3-value route discriminator
   (`none` / `ready` / `estimate`, last settled across transient `loading`/`unavailable`) + pickup/
   stops/destination coords only; ActiveRide = `status.name` + pickup/`stopPoints`/dropoff coords only;
   driver consumer = next-waypoint coordinates + route status ONLY, where status is a 3-value
   discriminator: none (`route == null`), ready (`!isEstimate`), estimate (`isEstimate`). `fetchedAt`,
   moving rider/driver GPS fixes and same-endpoint geometry changes are explicitly excluded.
   `none → ready` (the road route arriving) is a material change and auto-fits once; `ready → ready`
   refreshes and same-endpoint reroutes are not. Therefore a silent 30 s `trip_route_provider`
   refresh or a 200 m driver refetch neither auto-fits nor resets the cycle.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- **Run one Flutter/Melos agent at a time.** Melos shares the workspace `/.dart_tool`; concurrent
  agents can corrupt or cross-contaminate the build/test state.
- Landing requires the new shared suites plus the two updated rider suites to be green and the full
  `melos run test` to pass.
- **UNVERIFIABLE in this WSL harness:** real Android/iOS device behavior — a real GPS fix, the OS
  permission dialog, the actual `FlutterMap` camera animation, and touch placement on physical
  hardware. Close on a device/host before claiming device-level behavior.
- **Dangling-`depends_on` check:** this plan's `depends_on` is `[]`, so there is nothing to resolve.
  The separate driver plan is expected to reference this file by path; that reference is authored in
  the driver domain, not here.
