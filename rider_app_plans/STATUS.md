# rider_app — Status

> Flutter rider app (`rider_app/` + the shared `shared/` package). Owner: `rider-planner`.
> Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see Verification).

## Landed

### [tracking]
- WS contract: typed `ride.updated` / `driver.location` handling and the `no_driver_available`
  status — `rider_app/lib/features/home/data/ride_status_provider.dart:7,66-75,79-148`; tests
  `rider_app/test/features/home/data/ride_status_provider_test.dart`.
- Real cancel + `GET /rides/current` 5 s poll — `features/home/data/home_provider.dart:243-262`
  (`cancelRide`), `features/home/data/current_ride_provider.dart:72-111`,
  `features/home/presentation/active_ride_screen.dart:50-89`,
  `features/home/presentation/driver_matching_screen.dart:44-75`; tests
  `current_ride_provider_test.dart`, `driver_matching_screen_test.dart`, `active_ride_screen_test.dart`.
- Poll self-stops on terminal statuses (bug #8): `_isTerminalStatus` (`no_driver_available` /
  `cancelled` / `completed`) `features/home/data/current_ride_provider.dart:90-93`, checked after
  every poll `:111-113`; `@visibleForTesting isPolling` `:87-88`; tests
  `test/features/home/data/current_ride_provider_test.dart:62-99`.
- Ride detail + receipt + rating (LC-3) — `features/home/data/ride_provider.dart` `fetchRide:121`,
  `fetchReceipt:147`, `resolveFare:168`, `rateRide:187` (per-ride `RatingOutcome`, a 409
  `UNIQUE(ride_id, rater_role)` maps to `alreadyRated`, not failure); **ride-scoped** `canRate:104`
  (`!isRating && !ratedRideIds.contains(rideId)`; `ratingRideId` scopes the transient outcome so a
  rated ride no longer suppresses every later ride). The shared `AppRatingSheet` `busy` prop
  (`shared/lib/src/rating/app_rating_sheet.dart:73,111-113`, passed as `state.isRating` at
  `rating_prompt_dialog.dart:39`) disables the stars/submit for the in-flight window
  (double-submit guard over an unhardened backend); completion
  flow `active_ride_screen.dart:207-222`, receipt dialog `:227-286`, manual receipt `:323-333`,
  rating prompt `:297-314`; tests `test/features/home/data/ride_provider_test.dart`.
- Typed live driver tracking (LC-4) — `features/home/data/driver_tracking_provider.dart`
  (`pollInterval` 5 s `:57`, `wsSilenceTimeout` 10 s `:58`, `noteWsLocation:97`, `pollNow:123`
  folding the fix back into `rideStatusProvider` so WS and HTTP share one marker source); screen
  consumes typed `RideState.driver`/`driverLocation` (`active_ride_screen.dart:396-399`,
  `_buildDriverInfoSheet:537-556`, `rating <= 0` → "New driver" `:548-550`), driver marker bound to
  `driverLocation` `:449-455`; tick starts `:355-357` and stops on terminal/dispose `:375-387`;
  tests `test/features/home/data/driver_tracking_provider_test.dart`.
- Single-flight rider cancel + honest status handling — `ActiveRideScreen._cancelRide` sets a local
  `_cancelInFlight` **before** the confirm dialog, guards `_cancelInFlight || _leaving`, clears it
  in `finally`, and binds the `Cancel Ride` button to the same busy signal
  (`onPressed: _cancelInFlight ? null : _cancelRide`) —
  `features/home/presentation/active_ride_screen.dart:67,184-189,246,968`. The typed
  `CancelOutcome {success,notFound,conflict,failed}` returned by
  `RideCreationNotifier.cancelRide` maps `404`→`notFound`, `409`→`conflict`, and everything else
  (including today's `400`, `422`, `5xx`, transport failures)→`failed`, while `cancelError` keeps
  the API's public message — `features/home/data/home_provider.dart:255-262,351-388`. UI outcomes:
  `200` → one success feedback + home; `404` → silent home (dead trip, no misleading error); `409`
  → API message, stay on trip, no automatic retry; `failed` → retryable error, stay
  `features/home/presentation/active_ride_screen.dart:220-239`. One-shot
  `_acknowledgeCancelled` / `_cancelAcknowledged` `:71,250-260` serves both the POST success and
  the WS `cancelled` echo `:699`, so a fast echo cannot double-ack. `DriverMatchingScreen`'s
  existing guard is kept (not duplicated) and regression-pinned. Tests
  `test/features/home/presentation/active_ride_screen_test.dart:604-882` (single-flight, disabled
  button, `200`+WS one SnackBar, `404`, `409`, `500`),
  `test/features/home/data/home_provider_test.dart:62-119` (all four outcomes) and
  `test/features/home/presentation/driver_matching_screen_test.dart:144-185`.

### [ontrip]
- Live road route (pickup → stops → dropoff) — `features/home/data/trip_route_provider.dart`
  (`TripRouteStatus` `:21`; the additive `stops` itinerary is concatenated leg-by-leg over
  `GET /navigation/route` `:147-214`; injectable 30 s refresh `:53-54,97-110`; any failed or
  malformed leg → `_fail:229-236` with an **empty** polyline). `active_ride_screen.dart` draws
  solid blue only when `hasRoadRoute`, grey-dashed for `isEstimate`, and **nothing** on failure
  `:425-439`, with the estimate/error banner `:460-466,476+`.
- ETA honesty — `features/home/data/trip_eta.dart:5,12-17`: the backend `300` s placeholder is
  "unknown" and rendered as `ETA unavailable`, never rounded into a fake time
  (`active_ride_screen.dart:552-556`); tests `test/features/home/data/trip_route_provider_test.dart`.
- Honest per-status chip (bug #29 fixed): `_getStatusText` is exhaustive over `RideStatus` with no
  `default` — `driverArrived` → `Driver arrived`, `matching` → `Finding your driver`, plus explicit
  `cancelled`/`noDriverAvailable`/`idle` — `features/home/presentation/active_ride_screen.dart:1076-1096`.
  Tests `test/features/home/presentation/active_ride_screen_test.dart:1498-1533`.
- Active-trip itinerary pins + change-destination confirmation (R-1 + R-3): `TripRouteState` exposes
  the ordered intermediate `stopPoints` + `pickup`/`dropoff`/`vehicleType` from the same
  `GET /rides/:id` read `features/home/data/trip_route_provider.dart:35-49,171-189`; the active-ride
  map draws Home's `trip_origin`/`location_on` markers distinct from rider/driver
  `active_ride_screen.dart:704-747`; `_changeDestination` fetches a fresh `POST /estimates/price`
  (booked type) and only `PUT`s after Confirm, Cancel leaves the ride untouched
  `active_ride_screen.dart:237-250,262-387`. Tests `test/features/home/data/trip_route_provider_test.dart:227-242`,
  `test/features/home/presentation/active_ride_screen_test.dart:1248,1694-1707`.
- Live driver-arrival ETA (plan option R1, client-computed): `DriverEtaNotifier` computes
  driver→pickup via `GET /geo/eta` while `driverApproaching`, throttled (30 s tick / 150 m early
  trigger / 5 s floor) and writes `RideState.etaSeconds`/`etaDistanceM` through `applyLiveEta`;
  `300`/null/non-positive is never written and a failed compute keeps the previous value —
  `features/home/data/driver_eta_provider.dart:64-88,118-121,157-200`; per-status semantics (`driverArrived`/`onTrip`/terminal
  show no countdown) and the `X km · ETA N min` label `active_ride_screen.dart:1016-1025`. Tests
  `test/features/home/data/driver_eta_provider_test.dart:168-221`.
- Per-ride throttle reset + stale-response generation guard (bug #30): `_resetThrottle()`
  (`features/home/data/driver_eta_provider.dart:160-169`) clears `_referenceFix`/`_lastRequestAt`/
  `_lastCompute` and bumps `_generation`, is called by `stop()` (`:149-153`) — every transition out
  of `driverApproaching` (all terminal statuses) and dispose — and on the entering edge
  (`:116,122`). A `/geo/eta` response is applied only while its captured generation still matches
  (`:186,219,233,239`) and the in-flight marker is generation-scoped (`_inFlightGeneration`
  `:98,190,201,243`), so a stale response can neither re-set `_referenceFix`/write ETA into a later
  ride nor swallow its immediate compute. Within-ride 5 s floor, 150 m trigger and `300 == unknown`
  honesty unchanged. Tests `test/features/home/data/driver_eta_provider_test.dart:281-348`
  (per-ride reset via `in_progress` + terminal `no_driver_available`), `:350-419` (stale in-flight
  regression, RED→GREEN).

### [arrival]
- Driver-nearby + auto-arrival consumption (X3-R): `DriverLocation` parses the additive
  `near_pickup`/`distance_to_pickup_m` (nullable — Go `omitempty` drops a genuine `0.0`, so null is
  "unknown", never `0 m`) `features/home/model/driver.dart:97-98,106-107,117-118`; threaded into
  `RideState` and cleared when the status leaves `driverApproaching`
  `features/home/data/ride_status_provider.dart:166-180`; the "driver is nearby" notice renders only
  while `driverApproaching && nearPickup` `features/home/presentation/active_ride_screen.dart:904,1030-1042`.
  Auto-arrival needs no new code — the landed `driver_arrived` → `driverArrived` mapping and the
  status listener react. Tests `test/features/home/data/ride_status_provider_test.dart`,
  `test/features/home/presentation/active_ride_screen_test.dart:1814-1874`.

### [multi]
- Pre-booking stop list (Home) — ordered `List<Place> _stops` with add/remove/reorder:
  `features/home/presentation/stop_list.dart:13` (`applyStopReorder`), `:30` (`StopList`);
  `features/home/presentation/home_screen.dart:45` (state), `:118-145` (`_addStop` /
  `_removeStop` / `_reorderStops`), `:410-416` (render + fare note). Order in the list **is**
  the itinerary (no client `sequence`); stop markers join the camera fit `:76-100`, `:251-261`.
- Multi-leg honest preview (pickup → stops → destination) — `features/home/data/multi_leg_route_provider.dart:89-129`
  routes each consecutive pair through `GET /navigation/route` and concatenates the **API**
  geometry (`_fetchLeg:131-146`); any `is_estimate` leg makes the whole preview an estimate, any
  failed/malformed leg fails it with **no** polyline (`:105-121`). Consumed by Home through the
  unchanged `HomeRoutePreview.fromAsync` (`home_screen.dart:176-182`). No client straight-line
  fallback.
- `POST /rides` stop payload — `features/home/data/home_provider.dart:185-218`: `stops` param
  `:193`, top-level `stops[]` sibling in list order with no `kind`/`sequence` `:208-218`, key
  omitted when empty `:213`; call site `home_screen.dart:647-665` (`:664`). Tests
  `test/features/home/data/home_provider_test.dart:229-297`.
- Mid-trip change destination — `features/home/data/change_destination_provider.dart:15-22`
  (`isDestinationChangeable` mirrors the API's changeable set), `:50-80`
  (`PUT /rides/:id/destination` `:59-62`, API `message` with 409/404 fallbacks `:66-71`);
  endpoint constant `core/api/endpoints.dart:17-18`; UI entry `active_ride_screen.dart:201-233`
  (`_changeDestination`), gated `:716-719`, button `:745-770`. Re-route relies on the existing
  `ride.updated` re-read; no client reprice/re-route. Tests
  `test/features/home/data/change_destination_provider_test.dart`,
  `test/features/home/presentation/active_ride_screen_test.dart:1010,1093`.
- Fare honesty for stops (API gap, client-honest) — **SUPERSEDED** by the waypoint-aware estimate
  in Landed `[fare]` (bug #13 fixed): the API now prices the ordered itinerary, so the
  single-leg limitation the client used to name no longer exists. The `_buildStopsFareNote` /
  `stops-fare-note` caveat is removed (pre-fix `home_screen.dart:474-499`;
  `home_screen_test.dart:455` asserts `findsNothing`). Stop-list UI and the multi-leg preview
  remain covered by `stop_list_test.dart` and
  `test/features/home/data/multi_leg_route_provider_test.dart:66-140`.

### [location]
- Manual pickup fallback when the device fix is unavailable — injectable `LocationAvailability`/`LocationService`/`locationServiceProvider` (`features/home/data/location_service.dart:7,18,72`) plus the additive `LocationHelper.isLocationServiceEnabled`/`openAppSettings`/`openLocationSettings` wrappers (`shared/lib/src/utils/location_helper.dart:39-47`); `_defaultMapCenter` (`features/home/presentation/home_screen.dart:50`) + `_searchBias()` (`:249`) bias the pickup search (pickup → device fix → map center → default, never written as a location); the pickup field always opens `/location-search` with that bias and a `Use current location` clear (`:440-471`); the persistent notice offers `Open settings`/`Open location settings` + `Try again` (`:580-640`); `_createRide` remembers the pickup (`:801`). Tests `test/features/home/data/location_service_test.dart` (6), extended `home_screen_test.dart`, `location_search_screen_test.dart`.
- Android location permission in the main manifest (bug #16) — `ACCESS_FINE_LOCATION` +
  `ACCESS_COARSE_LOCATION` `rider_app/android/app/src/main/AndroidManifest.xml:3-4` and
  `<uses-feature android:name="android.hardware.location.gps" android:required="true"/>` `:5`; no
  `ACCESS_BACKGROUND_LOCATION`, no minSdk change. Manifests-only — the `deniedForever` deep-link UX is
  the separate landed fallback above.

### [trip]
- Pre-trip pickup recovery after a trip ends — global `pickupMemoryProvider` (`PickupMemory` with `remember`/`markReturning`/`consumeReturn`/`clear`) survives `HomeScreen` disposal `features/home/data/pickup_memory_provider.dart:6,26,34,43,50`, with the centralized `markTripReturn`/`resetRideState` exit helper `features/home/data/trip_return.dart:9,22`; Home consumes the return intent in `initState` and post-frame resets state / restores the manual `Place` / re-fits (`features/home/presentation/home_screen.dart:74-103`); cancel + no-driver exits mark `restore: true` (`driver_matching_screen.dart:61-65`, `active_ride_screen.dart:194,381-386,463`) and completion marks `restore: false` (`active_ride_screen.dart:372-375`); logout clears the memory (`core/auth/auth_provider.dart:79-81`). Tests `test/features/home/data/pickup_memory_provider_test.dart` (5), extended home/matching/active-ride suites.
- Post-auth live-trip restore (X1-R): the bootstrap also calls `checkOnce()` and a pure
  `resolvePostAuthRoute` maps `pending` → `/driver-matching`, `accepted`/`driver_arrived`/`in_progress`
  → `/active-ride`, everything else → `/home`; `pending` now counts in `needsRestore` and the
  unreachable `completed` was dropped — `features/home/data/current_ride_provider.dart:159-166`,
  `core/router/post_auth_route.dart:18-31`; a fresh login restores too
  (`features/auth/presentation/login_screen.dart:94-103`); the caller-less `RideStatusNotifier.restore()`
  was deleted. Tests `test/core/router/app_router_test.dart:14-48`,
  `test/features/auth/presentation/login_screen_test.dart`, `test/features/home/data/current_ride_provider_test.dart`.

### [web]
- Ride creation on web/CORS: backend allows `Idempotency-Key`
  (`internal/router/router.go:55`; asserted `internal/router/router_test.go:32`); shared
  cross-platform WS with query token (`shared/lib/src/network/websocket_service.dart:3,56-58`);
  dispatch pushes `no_driver_available` (`internal/service/dispatch.go:59-64,67-76,92`).

### [map]
- Zoom-to-fit the whole itinerary (pickup → stops → destination) —
  `features/home/presentation/home_screen.dart:76-100` (`_fitItinerary` / `CameraFit.bounds`;
  every stop marker and the destination are in the fitted point set).
- Dropoff + stop marker refresh — `home_screen.dart:223-274` (MarkerLayer gate includes
  `_stops`/`_destination`).
- Server route polyline — `features/home/data/home_provider.dart:83-107` (`NavigationRoute`,
  `isEstimate` parsed `:104`), `:131-144` (`navigationRouteProvider`). Home now routes the
  preview through the multi-leg provider instead — `features/home/data/multi_leg_route_provider.dart:89-129`
  (same `NavigationRoute` vocabulary, one API leg per consecutive pair) — watched at
  `home_screen.dart:176-182` (`navigationRouteProvider` is retained but no longer consumed by
  Home; see Landed `[multi]`).
- Route-preview failure honesty (`[map]_route_failure_honesty.md`): a single
  `HomeRoutePreview.fromAsync` (`features/home/data/home_route_preview.dart:68-115`) derives one
  status from the `AsyncValue<NavigationRoute>` reusing `TripRouteStatus`
  (`features/home/data/trip_route_provider.dart:21`), and both the `PolylineLayer` and the info
  row consume it, so the map and the numbers cannot disagree. `ready` → solid blue **API**
  geometry (`home_screen.dart:210-222`); `estimate` → grey dashed **API** geometry + `"Estimated "`
  (`:210-222,543`); `unavailable` (an error, or a `<2`-point body) → **no polyline** + the API
  message (`apiErrorMessage`) + Retry (`home_route_preview.dart:72-94`,
  `home_screen.dart:505-522`); `loading` → no polyline + a quiet `Finding route…` row (`:524-537`);
  a failed refresh with a retained value keeps the previous **road** geometry and surfaces the
  error (`isStale`, `home_route_preview.dart:66,82-114`) instead of swapping in a straight line.
  No client-synthesized straight line remains; this supersedes the earlier straight-line fallback,
  and the `[multi]` multi-leg preview above reuses the same derivation unchanged.
  Tests `test/features/home/data/home_route_preview_test.dart` (9),
  `test/features/home/presentation/home_screen_test.dart` (9, incl. the 2 `[multi]` cases), plus
  `is_estimate` parsing in `test/features/home/data/home_provider_test.dart:299-319`.
- Android tile access + one shared OSM-compliant tile path (bugs #14/#15; test-seam bug #25) —
  `INTERNET` added to the main manifest `rider_app/android/app/src/main/AndroidManifest.xml:2` (a release
  APK now has network); the single `TileLayer` construction moved to shared: `MapTileConfig.openStreetMap`
  (truthful contact-bearing UA `'<appName>/<appVersion> (+contact: <contact>)'`, never a browser string;
  placeholder `defaultContact = 'tiles@example.invalid'` for callers that do not override it)
  `shared/lib/src/map/map_tile_config.dart:7,21,32,59,61`, `buildMapTileLayer` + nullable
  `mapTileLayerProvider` `shared/lib/src/map/map_tile_layer.dart:10,21`, `MapTileAttribution`
  `shared/lib/src/map/map_tile_attribution.dart:8`, barrel `shared/lib/ride_hailing_shared.dart:27-29`,
  `shared/pubspec.yaml:19` (`flutter_map: ^7.0.2`). Rider builds only a config
  (`rider_app/lib/core/map/rider_map_tile.dart:9-17`; real `com.example.rider_app`, UA
  `rider_app/1.0.0 (+contact: ricardoapuch@gmail.com)`) from `rider_app/lib/config.dart:8,15,19`
  (`MAP_TILE_URL`/`MAP_TILE_API_KEY`/`APP_VERSION`) and both maps render the shared factory + attribution
  with **no** app `TileLayer` (`features/home/presentation/home_screen.dart:384-385,490`,
  `features/home/presentation/active_ride_screen.dart:490-491,542`). Bug #25 resolved — the nullable seam
  makes the map widget tests hermetic via `mapTileLayerProvider.overrideWith((ref, config) => null)`
  (`test/features/home/presentation/home_screen_test.dart:131`,
  `test/features/home/presentation/active_ride_screen_test.dart:300`,
  `test/features/navigation/rider_sidebar_test.dart:84`). **Plan↔code drift:** the plan specified
  `APP_VERSION` `defaultValue: 'dev'`; the landed code uses `'1.0.0'` (restores the Settings footer),
  guarded by `test/features/settings/presentation/settings_screen_test.dart:59-69`.

### [home]
- Resizable Home booking panel (drag/scroll + snap; the map really shrinks) —
  `features/home/presentation/home_screen.dart`: session-only `homePanelSizeProvider` `:26`,
  `DraggableScrollableController` `:75-76`, `snap: true` + content-driven max capped `0.9`
  `:91,607-619`, the map's layout box shrinks via `AnimatedBuilder` + `SizedBox('home-map')`
  `:469-480`, `_fitItinerary` bottom padding tracks the panel `:162,181`, FAB lifted above the
  panel `:585-599`, keyboard inset padding `:634`. The handle (`_buildSheetHandle` `:737-772`)
  keeps its 48 dp `Semantics` min↔opening-size toggle/label `:747-751` and **adds a desktop/web
  mouse-only grabber**: the pure gate `shouldEnableSheetDragHandle`
  (`core/platform/sheet_drag_handle.dart:5-21`) is wired at `:738-741`, a `GestureDetector` keyed
  `home-sheet-handle` with `behavior: HitTestBehavior.opaque` and
  `supportedDevices: {PointerDeviceKind.mouse}` `:752-757` drives `_sheetController` through drag
  start/update `:364-385`, and a single end/cancel landing `_settleSheetDrag` `:396-422` snaps to
  `{min, initial, max}` with `animateTo`, honoring fling direction and passing velocity 0 on
  cancel `:386-391`. **No physics change** (the sheet controller already injects
  `AlwaysScrollableScrollPhysics`; the `SingleChildScrollView` `:628-635` is untouched). The
  mobile touch/scroll path is unchanged because the callbacks stay null when the gate is off
  `:758-761`; the mobile resize gesture remains the list-scroll drag. **Supersedes the 2026-10-08
  "no second drag recognizer" lock for desktop/web only** — the source comments `:732-735` record
  it, and the mobile lock survives via the platform gate. `[map]` honesty / single booking path /
  `StopList` `NeverScrollableScrollPhysics` invariants intact. Tests
  `test/core/platform/sheet_drag_handle_test.dart:5-43` and
  `test/features/home/presentation/home_screen_test.dart:1208-1216` (drag helper), `:1365-1437`
  (mouse up/down reaches max/min), `:1442-1461` (mouse-only `supportedDevices`),
  `:1467-1562` (cancel settle + drag-cancel callback), `:1567-1616` (fling direction), `:1618-1663`
  (Android inert + touch still resizes), plus the existing touch/handle-toggle cases `:1315-1363`.

### [routing]
- Routing data in the API — landed/superseded by the `api_plans/` series (A* engine
  `internal/routing/`, the OSM import script / `make import-osm`, strict param validation
  `internal/handler/platform.go:516-527`). Structural note: the plan specified
  `internal/service/router/`; the engine lives in `internal/routing/`.

### [fare]
- Pre-booking estimate shows the API **total** + a receipt-style breakdown — `RideEstimate` maps
  `total` and the additive legs (`distance_fare`/`time_fare`/`demand_multiplier`/
  `supply_multiplier`/`grade_uplift_pct`/`currency`) and no longer parses the dead `price` field
  `features/home/model/ride_estimate.dart:32-41,68-87,110`; the selected option renders
  `formattedTotal` plus base/distance/time/conditions/total lines, with a `climb +x%` note on the
  distance leg only when the uplift is non-zero and **no fuel line** —
  `features/home/presentation/ride_estimate_sheet.dart:115-171` (climb `:140-142`); currency
  comes from the API and an absent code renders the bare amount (`ride_estimate.dart:110`); tests
  `test/features/home/model/ride_estimate_test.dart`,
  `test/features/home/presentation/ride_estimate_sheet_test.dart`,
  `test/features/home/data/home_provider_test.dart:374-492`.
- Waypoint-aware pre-booking estimate (closes bug #13, rider half; API landed — `api_plans/STATUS.md` → Landed `[fare]`) —
  `priceEstimatesProvider` POSTs `/estimates/price` with an ordered `stops` body mirroring
  `createRide` (empty list omitted, so the no-stop body is unchanged); new `EstimateStop` /
  `PriceEstimateArgs` value types keep the family key stable across rebuilds —
  `features/home/data/home_provider.dart:29,51,97-118`. Home threads `_stops` into the request
  `features/home/presentation/home_screen.dart:584-593`; the obsolete `_buildStopsFareNote` and its
  `stops-fare-note` call site are removed (`home_screen_test.dart:455` asserts `findsNothing`).
- Honest waypoint estimate UI — `RideEstimate` parses the additive `is_estimate` + `legs`
  (`RideEstimateLeg`, `hasMultipleLegs`) `features/home/model/ride_estimate.dart:7,46,50,81-91`;
  the sheet renders an `Estimated fare — not fully road-routed` caption `:106-111` and an
  informational per-leg distance/duration breakdown `:154-180` (per-leg fares are never summed;
  `total` stays authoritative). Tests: `home_provider_test.dart:374-492` (`onPost` + POST-body
  assertion, incl. the ordered-stops case), `home_screen_test.dart:382-478` (ordered stops threaded;
  no `stops-fare-note`), `ride_estimate_test.dart:82-119` (`is_estimate`/`legs` parse + defaults).

### [auth]
- Real rider profile / account — `rider_app/lib/core/auth/auth_provider.dart:20,38-99`
  (`riderProfileProvider`, `refreshProfile`, `onLoggedOut` cache clearing);
  `features/profile/providers/profile_notifier.dart`; `features/home/presentation/profile_screen.dart`;
  shell drawer header `features/navigation/rider_shell.dart:49-68`; shared `AuthUser` fields
  `shared/lib/src/models/auth_user.dart:12-14,62` and the logout hook
  `shared/lib/src/auth/app_auth_controller.dart:84,231`. Tests present.
- Real forgot-password (bug #3): `AuthNotifier.forgotPassword(email)` POSTs
  `ApiEndpoints.forgotPassword` — `rider_app/lib/core/auth/auth_provider.dart:44-51`;
  `features/auth/presentation/forgot_password_screen.dart:38-64` drives success/error via
  `mapStatusCodeToException`; test
  `rider_app/test/features/auth/presentation/forgot_password_screen_test.dart`.
- Enter-to-submit on web/desktop only (rider login): a pure app-local
  `shouldSubmitOnEnter(isWeb:, platform:)` predicate
  `rider_app/lib/core/platform/enter_to_submit.dart:6-21` drives the login fields — email
  `TextInputAction.next` `features/auth/presentation/login_screen.dart:129`, password
  `TextInputAction.done` + `onFieldSubmitted` `:150-151` (both `null` on mobile, unchanged),
  feeding the one `_submit()` path behind a `_isSubmitting` double-submit guard `:47-96`. Tests
  `rider_app/test/core/platform/enter_to_submit_test.dart` and
  `rider_app/test/features/auth/presentation/login_screen_test.dart:350-448` (desktop Enter once /
  mobile never / in-flight double never). App-local only — no `shared/`/API/driver change.
- Web session persistence (stop clearing the session too eagerly) — shared `AppAuthController`:
  `_isDefinitiveAuthFailure` treats only **400/401** as a dead session (timeout / connection
  error / 5xx / 429 / parse stay transient) `shared/lib/src/auth/app_auth_controller.dart:135-144`;
  `checkAuth` recovers a refresh-token-only cold start and retries `/me` once after a 401
  (`:146-204`); `refreshToken()` is single-flight (`:397-398`) and never calls `logout()` on
  failure — a definitive failure clears locally via `_clearLocalSession` (`:254-265`), a transient
  one keeps the tokens (`:435-445`); a throwing storage read is `readFailed` and keeps the session
  (`_RefreshOutcome` `:19-25`, `_doRefresh` `:403-410`, `_settleFailedRefresh` `:228-237`); `login`
  hardens `saveTokens` (`:340-348`). Web `AuthStorage` picks `window.localStorage` at compile time
  via a conditional import (`shared/lib/src/auth/auth_storage.dart:4-5`,
  `auth_key_value_store_web.dart:11,33`) with reads returning `null` / writes swallowing
  (`auth_storage.dart:59-81`); `shared/pubspec.yaml:17` adds `web: ^1.1.1`. Tests
  `shared/test/auth/app_auth_controller_test.dart` (+13: single-flight, definitive/transient, the
  throwing-read and `onLoggedOut`-once cases) and `shared/test/auth/auth_storage_test.dart`
  (round-trip, failure swallowing, and the web-only `localStorage` test skipped on the VM at
  `:93-104`, verified on Chrome). Dev port pinned `scripts/dev-all.sh:30,50-52,100-103`.
- Web-reload session bootstrap (X2-R, chain head): `checkAuth()` plus the one-shot ride restore run
  once on **every** entry path before the router reads the session, and the `redirect` gates on a
  bootstrap-resolved flag so a reload cannot bounce to `/login` — `core/app_bootstrap.dart:19,31`
  (`SessionBootstrap.run`, idempotent; `checkOnce` only when authenticated), `app.dart:8,23` (root
  `initState` schedules it), `core/router/app_router.dart:31-33` (`refreshListenable` + `resolveRedirect`),
  `core/router/post_auth_route.dart:59-88` (unresolved → `/splash`; an active ride wins over a
  deep-linked shell section). Tests `test/app_bootstrap_test.dart`,
  `test/core/router/app_router_test.dart:50-164`. **Test gap closed** by Landed `[test]` (bug #31):
  the full-widget reload test lives below.

### [push]
- Rider device-token registration seam (register on every authenticated transition, unregister
  **before** the bearer is cleared, best-effort): `PushTokenSource` interface +
  `DevicePlatform`/`currentDevicePlatform` `core/push/push_token_source.dart:8,24,46,59`;
  `DeviceTokenService` (`register:52`, `registerToken:64` → `POST /devices {token,platform}`,
  `unregister:80` → `DELETE /devices/{token}`) `core/push/device_token_service.dart:52,64,80`,
  provider `:103`; endpoints `core/api/endpoints.dart:34-36`; auth wiring — register on
  authenticated `core/auth/auth_provider.dart:64`, unregister before `super.logout()`
  `:89,93`; service materialized for the app lifetime `app.dart:15`. Tests
  `test/core/push/device_token_service_test.dart` (15). **Deferred:** `pushTokenSourceProvider`
  still ships `NoopPushTokenSource` (`push_token_source.dart:71-73`) — no FCM/APNs SDK in the
  workspace, so no token is minted and the whole service degrades to a no-op; installing a real
  source is a single provider override. Server delivery stays inert until a real `MultiProvider`
  is wired (api_plans `[push]`).

### [nav]
- Shared sidebar / settings / profile core + theme tokens — the first UI in `shared/` (17 files under
  `shared/lib/src/{navigation,settings,profile}/`): `AppSidebar` + `closeSidebar`
  `shared/lib/src/navigation/app_sidebar.dart:22,102`, `AppNavDestination`
  `shared/lib/src/navigation/app_nav_destination.dart:17`, `AppNavSection`
  `shared/lib/src/navigation/app_nav_section.dart:7`, `AppSidebarFooter`
  `shared/lib/src/navigation/app_sidebar_footer.dart:14`, `AppNavLinkCard`
  `shared/lib/src/navigation/app_nav_link_card.dart:22`, `AppSettingsScreen`
  `shared/lib/src/settings/app_settings_screen.dart:20`, `AppProfileHeader`
  `shared/lib/src/profile/app_profile_header.dart:25`, `AppProfileForm`
  `shared/lib/src/profile/app_profile_form.dart:30`; barrel exports
  `shared/lib/ride_hailing_shared.dart`; spacing/radius/type tokens
  `shared/lib/src/theme/app_theme.dart`. Widget suites `shared/test/{navigation,settings,profile}/`.
  `AppSidebar.selectedRoute` is now consumed by both apps' shells (see below), so its
  "no app passes it yet" doc comment was retired.
- Rider adoption: drawer → `AppSidebar` `features/navigation/rider_shell.dart:58`; app-owned list
  `features/navigation/rider_nav_items.dart:20`; shared toggle (double inset removed)
  `features/home/presentation/home_screen.dart:215`; profile →
  `AppProfileHeader`/`AppProfileForm`/`AppNavLinkCard`
  `features/home/presentation/profile_screen.dart:81,99,110`. Tests `test/features/navigation/`.
  **Settings is a body-only screen**, composing the shared `AppSettingsSection`/`AppSettingsRow`
  rows directly — `features/settings/presentation/settings_screen.dart:8-19,30-73`. It does NOT
  use `AppSettingsScreen`, which hardcodes its own `Scaffold`/`AppBar` and therefore cannot nest
  in the shell (see Invariants). Test `test/features/settings/presentation/settings_screen_test.dart`.
- App-wide drawer via `ShellRoute` (bug #9): `RiderShell` owns the single `Scaffold` + `AppSidebar`
  + route-aware `AppBar` — `rider_app/lib/features/navigation/rider_shell.dart:26-92`; wraps the
  six sections (`/home`, `/profile`, `/history`, `/payment`, `/security`, `/settings`) in
  `rider_app/lib/core/router/app_router.dart:56-86`; `selectedRoute: path` `rider_shell.dart:69`;
  flow routes (`/location-search`, `/driver-matching`, `/active-ride`) stay outside
  `app_router.dart:87-105`; tests `test/features/navigation/rider_shell_test.dart:71-105,157-169`.
- Home as a first-class destination — shared `AppNavSection.home('HOME')` first
  `shared/lib/src/navigation/app_nav_section.dart:8`; `AppNavDestination.home('home', 'Home',
  Icons.home_outlined, AppNavSection.home)` first `shared/lib/src/navigation/app_nav_destination.dart:18`;
  prepended to the rider list `features/navigation/rider_nav_items.dart:21-24`, so the profile card
  gains the row automatically from the same list minus `profile`
  `features/home/presentation/profile_screen.dart:110-115`. Parity suites moved:
  `shared/test/navigation/app_nav_item_test.dart`, `test/features/navigation/rider_nav_items_test.dart`.
  No barrel edit (both files already exported) and no shim.
- Universal back navigation — new shared router-free `AppBackButton` (explicit `onPressed` wins →
  pop if `canPop` → `onFallback`; `shared/` calls no `go`/`push`) `shared/lib/src/navigation/app_back_button.dart:14-49`;
  barrel `shared/lib/ride_hailing_shared.dart:32`. Rider shell decision D1-B: the five non-home
  sections render `leading: AppBackButton(onFallback: → /home)` with `actions: [AppSidebarToggleButton]`
  `features/navigation/rider_shell.dart:87-93`; `/home` stays `appBar: null` (edge-to-edge overlay
  toggle). Sub-screens: `/location-search` `features/home/presentation/location_search_screen.dart:56`;
  `/register` → `/login` `features/auth/presentation/register_screen.dart:49`; `/forgot-password` →
  `/login` `features/auth/presentation/forgot_password_screen.dart:69`; `/driver-matching` reuses its
  leave/cancel handler `features/home/presentation/driver_matching_screen.dart:142-144`; `/active-ride`
  overlay `AppBackButton(onPressed: _handleBack)` `features/home/presentation/active_ride_screen.dart:567-572`
  (`_handleBack` reuses cancel-confirm / `_goHome`, `:403-410`). `/login`, `/splash`, `/home` stay
  roots with no back. Tests `shared/test/navigation/app_back_button_test.dart` (6) + the rider
  shell/nav/sidebar/location-search/driver-matching/active-ride/register/forgot/login/splash suites.

### [design]
- Shared style system — extended token set: `AppColors` semantic roles + the exact
  `routeReady == Colors.blue` / `routeEstimate == Colors.grey` aliases
  `shared/lib/src/theme/app_colors.dart:21-69`; role `AppTextStyles` + `AppRadii.sheet`/`dialog`/
  `pill`/`handle` `shared/lib/src/theme/app_theme.dart:13-96,151-153` (Material mappings preserved,
  incl. `dialog == 28`); `AppElevation` `app_elevation.dart:10-16`; `AppMotion`
  `app_motion.dart:10-18`; barrel `shared/lib/ride_hailing_shared.dart:8-14`.
- Shared component library (9 pure files — no providers, `go_router` or `ApiConfig`): `AppButton`
  `shared/lib/src/components/app_button.dart:28`, `AppTextField` `app_text_field.dart:9`, `AppCard`
  `app_card.dart:8`, `AppListTile` `app_list_tile.dart:8`, `AppBottomSheet`/`AppSheetHandle`
  `app_bottom_sheet.dart:10,55`, `AppEmptyState` `app_empty_state.dart:12`,
  `AppErrorState`/`AppErrorRow` `app_error_state.dart:10,52`, `AppSectionHeader`
  `app_section_header.dart:6`, `AppStatusChip`/`AppBadge` `app_status_chip.dart:11,42`; barrel
  `:15-23`; tests `shared/test/theme/app_tokens_test.dart` (6) + `shared/test/components/*` (19),
  25 total.
- Rider migration: 12 feature files consume the components; the rider-local `AuthTextField` was
  **deleted** (no new shim, no app file moved into `shared/`) and its call sites now use the shared
  `AppTextField` (`features/auth/presentation/login_screen.dart:104,114`;
  `register_screen.dart:57,66,75`; `forgot_password_screen.dart:107`).
- Deliberate deferral (not a bug): `AppBadge` is exported/tested but has **zero production
  consumers yet** — it is consumed by the driver counterpart
  (`driver_app_plans/[design]_shared_style_adoption.md`). `AppMotion` now has a rider consumer
  (the landed `[home]` resizable panel, `home_screen.dart:349-350,546`).

### [rating]
- Unified cross-app rating UI (one shared presentation-only widget) — `AppRatingSheet` +
  `showAppRatingSheet` `shared/lib/src/rating/app_rating_sheet.dart:19,73,109,115,176` (unselected
  grey / selected amber via `AppColors.muted`/`AppColors.warning` `:119-121`), barrel
  `shared/lib/ride_hailing_shared.dart:42`; rider `rating_prompt_dialog.dart:14-54` hosts it
  (`allowComment: true`, `failed`→hold / success+`alreadyRated`→pop `RatingOutcome`), the
  `active_ride_screen.dart:352-366` gate unchanged, POST body `{score, comment}`
  `ride_provider.dart:203-206`; driver `rate_sheet.dart:9-70` is a thin wrapper preserving
  `showRateSheet`, both call sites, `markRated`, the snackbar, the two error strings and the
  `rate-comment`/`rate-submit`/`rate-skip`/`rate-error` keys. Tests
  `shared/test/rating/app_rating_sheet_test.dart` (9).

### [search]
- Throttled place autocomplete: `placeSearchDebounceProvider` (`Provider<Duration>`, default
  350 ms) — `features/home/data/home_provider.dart:53-54`; `LocationSearchScreen._onQueryChanged`
  cancels the previous `_debounceTimer` and re-arms it, and `dispose` cancels it —
  `features/home/presentation/location_search_screen.dart:28,31-43`; one request per query at a
  single fixed `_searchRadiusM = 30000.0` (the `_radiusSteps` 4-request loop is gone) —
  `features/home/data/home_provider.dart:51,56-74`; tests
  `test/features/home/data/home_provider_test.dart:251-302` (single request + single radius, blank
  query) and `test/features/home/presentation/location_search_screen_test.dart:63-95` (debounced
  keystroke stream → one request).

### [history]
- Real paginated ride history (bug #4): `features/home/data/history_provider.dart` —
  `firstPage:56`, `loadMore:61-67` guarded by `nextPage > state.totalPages` (`:64`, no out-of-range
  request), `{rides,page,total_pages}` envelope parsed `:69-86`; `RideSummary.fromJson` model
  `features/home/model/ride_summary.dart:1-33`; `history_screen.dart` pull-to-refresh
  `RefreshIndicator` `:46`, infinite-scroll trigger `_onScroll:32-38`, distinct
  loading `:50-52` / error+Retry `:53-62` / empty `:63-68` states; tests
  `test/features/home/data/history_provider_test.dart:94-149`,
  `test/features/home/presentation/history_screen_test.dart`.
- Honest already-rated seed past the 1000-row cap (bug #11) — rider
  `RatingStatus{rated,unrated,unknown}` with `canRate` true only for `unrated`
  (`features/home/data/ride_provider.dart:26-40`); `riderRatedRideIdsProvider` returns a
  `RatedRideSeed` and flags `partial` when the envelope `total` exceeds 20 × 50 (`:272-324`);
  `riderRideRatingStatusProvider` resolves in-session → a seed hit → a complete-seed miss
  (`unrated`) → the truncated-seed `GET /rider/ratings?ride_id=<uuid>` existence lookup
  (`rated`/`unrated`) → `unknown` on any failure, so loading / failure / partial can never become
  a prompt (`:326-380`). `active_ride_screen.dart` seeds the fast path and gates the prompt on that
  provider (`:139-151,297-314`). Per-ride lookup uses the landed API `[history]` `ride_id` filter
  (`api_plans/STATUS.md` → Landed `[history]`; handler `internal/handler/ride.go:483-486`); tests
  `test/features/home/data/ride_provider_test.dart:455-792`.

### [geo]
- Rider-location ping (bug #7): `features/home/data/location_ping_service.dart` — 5 s throttle
  `:18,68-72`, `PUT /geo/rider/location` `:74-77` (204 body not parsed), 4xx swallowed `:78-80`,
  lease-counted `start`/`stop` `:35,42-66`; streamed from Home **and** matching + active-trip
  `features/home/presentation/home_screen.dart:32-50`,
  `driver_matching_screen.dart:32-53`, `active_ride_screen.dart:35-68`; tests
  `test/features/home/data/location_ping_service_test.dart`.
- `nearbyDriversProvider` consumer (bug #6): `FutureProvider.family<List<NearbyDriver>, LatLng>`
  parsing the real `{drivers:[...]}` envelope — `features/home/data/home_provider.dart:12-24`;
  `NearbyDriversChip` `features/home/presentation/nearby_drivers_chip.dart:6-21`, rendered on Home
  `home_screen.dart:305,395-404`; tests
  `test/features/home/presentation/nearby_drivers_chip_test.dart`.

### [safety]
- SOS with ack-only honesty (bug #5): `features/home/data/security_provider.dart:36-68`
  (`sendSos` → `POST /api/v1/sos`, last fix or ride-pickup fallback `:60-68`);
  `features/home/presentation/security_screen.dart:8-29` confirm dialog guards double-fire,
  success/error banners `:38-51`, honest caption `:80-84`; tests
  `test/features/home/data/security_provider_test.dart`,
  `test/features/home/presentation/security_screen_test.dart`. The authoritative skip list lives in
  Invariants below.

### [session]
- Guarded switch-account (new tag): shared `AppAuthController.needsAccountSwitch` is conservative
  for unknown/partial identity (the driver empty-email shape) —
  `shared/lib/src/auth/app_auth_controller.dart:135-161`; `cancelCurrentSession` revokes the current
  refresh token `:166`; `switchAccount` cancels then re-logs in `:171-176`; plain `login()` refuses
  to silently overwrite an authenticated session `:178-185`. Rider login confirmation
  `rider_app/lib/features/auth/presentation/login_screen.dart:52-75`. Tests
  `shared/test/auth/app_auth_controller_test.dart:63-227`,
  `rider_app/test/features/auth/presentation/login_screen_test.dart`.

### [test]
- Full-widget web-reload test (T1/T2, bug #31): an additive, production-defaulted
  `routerInitialLocationProvider` (`core/router/app_router.dart:25-28`, read at `:33`, default
  `/splash`) lets a widget suite boot the real `RiderApp` at `/home`; with a staged stored session
  the first frame shows the splash spinner (never `LoginScreen`) and it settles on `HomeScreen`; the
  no-token control settles on `LoginScreen` — `test/features/auth/presentation/app_reload_test.dart:107,120-145`.
  T1's real teeth are `resolveRedirect`'s `!bootstrapComplete` gate (removing it makes T1 fail); the
  seam itself does not discriminate (booting at `/splash` vs `/home` converges) and a **real browser
  reload remains UNVERIFIABLE in this WSL harness**.
- Shell back test across all five non-home sections (T3, bug #27): the
  `isHome ? null : AppBar(leading: AppBackButton…, actions: [AppSidebarToggleButton])` branch is
  asserted for `/profile`,`/history`,`/payment`,`/security`,`/settings`, each tap returning to
  `home-body` — `test/features/navigation/rider_shell_test.dart:87-117` (branch
  `features/navigation/rider_shell.dart:85-93`).
- Profile-card Home row assertions (T4/T5, bug #28): `nav-link-home` present, `nav-link-profile`
  absent, the exact row set, and tapping the Home row pushes `/home` —
  `test/features/home/presentation/profile_screen_test.dart:350-381` (card feed
  `features/home/presentation/profile_screen.dart:110-115`).

## Known bugs & issues

Source citations in this file are **relative to the app root** (`features/.../screen.dart:N`)
unless they cross a package, in which case they are repo-relative
(`rider_app/lib/...`, `shared/lib/...`, `internal/...`). Never cite a bare
`home_screen.dart` — both `rider_app` and `driver_app` have one.

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 1 | `ActiveRideScreen` read invented `driver_lat`/`driver_lng`/`driver_name`/`car_model` instead of typed `RideState.driver`/`driverLocation` — **FIXED** by LC-4: typed driver card + marker bound to `driverLocation`; no invented key reads remain (only comments) | `features/home/presentation/active_ride_screen.dart:396-399,449-455,537-556` | high | [tracking] |
| 2 | Home route `error: (_, _)` branch fired on **every** error status, drew a **client-synthesized straight** fallback, and discarded the exception; an `is_estimate` body also used the client's straight line instead of the API geometry — **FIXED** by `[map]_route_failure_honesty.md`: the branch is gone, no polyline is drawn on any error status, and the estimate uses the API geometry dashed + labeled | `features/home/data/home_route_preview.dart:68-115`; `features/home/presentation/home_screen.dart:210-222,505-522` | low | [map] |
| 3 | Forgot-password was a local `setState` fake; `ApiEndpoints.forgotPassword` dead — **FIXED**: `AuthNotifier.forgotPassword` POSTs the real endpoint and the screen drives success/error | `rider_app/lib/core/auth/auth_provider.dart:44-51`; `features/auth/presentation/forgot_password_screen.dart:38-64` | medium | [auth] |
| 4 | History screen hardcoded "No rides yet" — **FIXED**: paginated `historyProvider` + pull-to-refresh/infinite-scroll list with distinct empty/error states | `features/home/data/history_provider.dart:56-102`; `features/home/presentation/history_screen.dart:46,53-68` | medium | [history] |
| 5 | Security/SOS screen placeholder; `ApiEndpoints.sos` dead — **FIXED**: confirm-dialog SOS POST with the ack-only caption | `features/home/data/security_provider.dart:36-68`; `features/home/presentation/security_screen.dart:8-29,58-84` | medium | [safety] |
| 6 | `nearbyDriversProvider` declared but never consumed — **FIXED**: `family` provider consuming `{drivers:[...]}`, surfaced via `NearbyDriversChip` | `features/home/data/home_provider.dart:12-24`; `features/home/presentation/nearby_drivers_chip.dart:6-21` | low | [geo] |
| 7 | No code called `PUT /geo/rider/location` — **FIXED**: lease-counted `LocationPingService` (5 s throttle) started by Home + matching + active-trip | `features/home/data/location_ping_service.dart:42-81`; `features/home/presentation/home_screen.dart:32-50` | medium | [geo] |
| 8 | `current_ride_provider` poll only self-stopped on `no_driver_available`; cancel/complete relied on screen navigation — **FIXED**: self-stops on any terminal status | `features/home/data/current_ride_provider.dart:90-93,111-113` | low | [tracking] |
| 9 | Sidebar existed only on `/home`; `AppSidebar.selectedRoute` wired but unconsumed — **FIXED**: app-wide `RiderShell` `ShellRoute` consumes `selectedRoute`; flow routes stay drawer-free | `features/navigation/rider_shell.dart:26-92`; `core/router/app_router.dart:56-86` | low | [nav] |
| 10 | Place autocomplete fired one request per keystroke (no debounce) AND up to 4 sequential requests per query via the `_radiusSteps` 1000/3000/10000/30000 m loop — **FIXED** by `[search]_throttle_place_autocomplete.md`: 350 ms `placeSearchDebounceProvider` (`features/home/data/home_provider.dart:53-54`) with cancel-then-rearm `_debounceTimer` (`features/home/presentation/location_search_screen.dart:28,37-43`), and a single `_searchRadiusM = 30000.0` request (`features/home/data/home_provider.dart:51,56-74`) | pre-fix `features/home/presentation/location_search_screen.dart:50-52`; `features/home/data/home_provider.dart:51,58-73` | medium | [search] |
| 11 | `riderRatedRideIdsProvider` seed walk is a **documented bound**: `ratedRideIdsMaxPages` = 20 × 50 = 1000 rated rides. A rider past that ceiling could be re-prompted for an ancient completed ride — **FIXED** by `01_[history]_rated_seed_past_cap.md`: the seed is `partial` when `total > 1000` and a ride outside it is resolved with the `ride_id` filter; a truncated / loading / failed seed is `unknown`, never `unrated` | pre-fix `features/home/data/ride_provider.dart:239,247-271`; post-fix `features/home/data/ride_provider.dart:26-40,272-380` | low | [history] |
| 12 | Pre-booking estimate sheet showed the fixed `base_fare` instead of the computed `total`, and `RideEstimate` parsed a dead `price` JSON field the API never sends (always 0, unused) — **FIXED** by `[fare]_estimate_total_and_breakdown.md`: maps `total` + breakdown legs, removes `price`, renders the total with a receipt-style breakdown and API currency | post-fix `features/home/model/ride_estimate.dart:32-41,68-87,110`; `features/home/presentation/ride_estimate_sheet.dart:115-171`; pre-fix sheet `:108`, model `:26,58`; API sends `total`/`grade_uplift_pct` `internal/handler/responses.go:189,199` | medium | [fare] |
| 13 | **API gap (not rider work):** there was no waypoint-aware fare — `POST /rides` priced `pickup → dropoff` only and ignored the `stops[]` itinerary, and `GET /estimates/price` took no stops, so a multi-stop trip was priced short; the rider UI stayed honest with the single-leg API number + `stops-fare-note`. — **FIXED** by the API half (coordinated API + rider wave; `api_plans/STATUS.md` → Landed `[fare]`): the API now prices the ordered itinerary (`RequestRide` → `CalculateItineraryEstimate`) and `POST /estimates/price` takes the same ordered `stops` body, and the rider switched to `POST` with stops and dropped the caveat (see Landed `[fare]`) | post-fix `internal/service/ride.go:264`; `internal/service/fare.go:158`; `internal/router/router.go:277`; `features/home/data/home_provider.dart:97-118`; pre-fix `internal/service/ride.go:234`; `features/home/presentation/home_screen.dart:474-499` | low | api_plans `[fare]` |
| 14 | **Android release build had no network:** `android.permission.INTERNET` was declared only in the debug/profile manifests, so a release APK had no tiles, API or WS at all (stock Flutter template behaviour, a shipping bug here). — **FIXED** by Landed `[map]`: `INTERNET` now sits in the main manifest and merges into every variant | post-fix `rider_app/android/app/src/main/AndroidManifest.xml:2`; pre-fix absent; `src/debug/AndroidManifest.xml:6`; `src/profile/AndroidManifest.xml:6` | high | [map] |
| 15 | **Android maps showed OSM "Access Blocked":** both maps sent a hardcoded spoofed desktop Chrome `User-Agent`; because `NetworkTileProvider(headers:)` already carried that key, flutter_map's `putIfAbsent` never injected `userAgentPackageName`, so OSM blocked the browser-spoofed app traffic; `userAgentPackageName: 'com.rider.app'` also mismatched the real `applicationId` `com.example.rider_app`. — **FIXED** by Landed `[map]`: the spoofed UA is gone, the shared factory sends the truthful contact-bearing UA via `MapTileConfig.headers`, `userAgentPackageName` is `com.example.rider_app`, and both maps render through the shared factory + attribution | post-fix `shared/lib/src/map/map_tile_config.dart:21,32,61`; `rider_app/lib/core/map/rider_map_tile.dart:11`; pre-fix `features/home/presentation/home_screen.dart:196-205`; `features/home/presentation/active_ride_screen.dart:476-484`; `rider_app/android/app/build.gradle.kts:18` | high | [map] |
| 16 | **Android `geolocator` threw "No location permissions are defined in the manifest":** the main manifest declared neither `ACCESS_FINE_LOCATION` nor `ACCESS_COARSE_LOCATION`, so Home's `_initLocation`, the rider-location ping and the live-trip position stream all failed on Android. — **FIXED** by Landed `[location]`: `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` + `uses-feature gps required="true"` in the main manifest; no background location; no minSdk change | post-fix `rider_app/android/app/src/main/AndroidManifest.xml:3-5`; pre-fix absent; `shared/lib/src/utils/location_helper.dart:4-23` | high | [location] |
| 17 | **Test gap (tracked, not a code defect):** `rider_app/test/features/home/presentation/ride_estimate_sheet_test.dart` had no case for the Landed `[fare]` `is_estimate` caption (`Estimated fare — not fully road-routed`) or the informational per-leg breakdown; both sheet/model paths are implemented — **FIXED**: the sheet suite now asserts the caption + `Trip legs`/`Leg 1`/`Leg 2` breakdown together, plus a road-routed negative control that asserts neither renders | post-fix `test/features/home/presentation/ride_estimate_sheet_test.dart:225-263` (combined case + negative control); sheet `features/home/presentation/ride_estimate_sheet.dart:106-111,154-180`; model `features/home/model/ride_estimate.dart:7,46,50,81-91` | low | [fare] |
| 18 | Comment/condition drift (not a runtime defect): `_showLocationNotice`'s doc claimed the persistent notice required the rider "has not chosen a pickup", but the condition omits `_pickupLocation == null` — **FIXED** by `[design]`: the doc now states the notice persists after a manual pickup and clears only when a device fix arrives, matching the condition | `features/home/presentation/home_screen.dart:567-569` (comment) vs `:570-573` (condition) | low | [location] |
| 19 | **Test gap (tracked, not a code defect):** `[location]`/`[trip]` widget-coverage holes — the settings-action dispatch (`openAppSettings`/`openLocationSettings`) was never invoked from the widget, the restored pickup's route/estimate coordinates were not asserted, and the `remember(_pickupLocation)` call-site was untested — **FIXED** by `[design]`: three new cases add the settings-action dispatch, the restored-pickup route/estimate coordinates, and the `remember` call-site | `features/home/presentation/home_screen.dart:423,441,570-634,764`; tests `test/features/home/presentation/home_screen_test.dart:815-849,851-927,929-991` | low | [location]/[trip] |
| 20 | Destination/stop search still degraded when there is neither a device fix nor a manual pickup: the destination field's `origin == null` guard showed `Could not determine your location` and `_addStop` omitted `lat`/`lng`, so `LocationSearchScreen` short-circuited — **FIXED**: the destination field `onTap` unconditionally pushes with `_searchBias()` (`:465-485`); `_addStop` always supplies `lat`/`lng` (`:173-180`); the biased search never hits the `'Enable location to search nearby'` guard (`location_search_screen.dart:48-52,66-67`); and no location is fabricated — `_routePlan` still requires pickup/fix+destination (`:155-167`) and `canRequest` still requires pickup/fix (`:690-692`) | post-fix `features/home/presentation/home_screen.dart:465-485,173-180,155-167,690-692`; `features/home/presentation/location_search_screen.dart:48-52,66-67`; pre-fix `home_screen.dart:479-488,169-180`; tests `test/features/home/presentation/home_screen_test.dart:1022-1060,1062-1099,1101-1156` | low | [location] |
| 21 | Residual same-class gap (not covered by #20): **mid-trip change-destination** still omitted `lat`/`lng` when `_searchOrigin()` was null, so the generic `/location-search` could still show the blocking `'Enable location to search nearby'` branch from that surface — **FIXED**: `_changeDestination` always pushes with a `_searchBias()` center, and the bias stays in the route `extra` only (never written into the booking/destination) | post-fix `features/home/presentation/active_ride_screen.dart:211-219` (always pushes `lat`/`lng`), `:247-262` (`_searchBias()` order: trip pickup → `_riderPosition` → map center → `_defaultMapCenter`); `features/home/data/change_destination_provider.dart:59-62` (PUT body is the picked `{lat,lng,address}` only); pre-fix `active_ride_screen.dart:206-213` (`if (origin != null)` guard); test `test/features/home/presentation/active_ride_screen_test.dart:1111-1196` | low | [location]/[trip] |
| 22 | **Test gap (tracked, not a code defect):** the `findsNothing('Enable location to search nearby')` assertions were tautological wherever the test's `/location-search` route was a `SizedBox` stub — the string could never render there anyway; the real-screen guarantee rests on `location_search_screen_test.dart`. — **FIXED**: the tautological assertions were removed from the Home and change-destination suites and replaced by a mutation-proven negative-control pair that brackets the real guard (non-null bias ⇒ blocking text absent; null bias ⇒ present, so the check can actually fail when the production branch flips) | post-fix `test/features/home/presentation/location_search_screen_test.dart:100-119`; tested guard `features/home/presentation/location_search_screen.dart:48-52,66-67`; pre-fix `test/features/home/presentation/home_screen_test.dart:1098` vs the stub route `:185-193`, `test/features/home/presentation/active_ride_screen_test.dart:1164` vs the stub route `:275-293`; real-screen coverage `test/features/home/presentation/location_search_screen_test.dart:61` | low | [location] |
| 23 | **Test gap (tracked, not a code defect):** the `[home]` handle-toggle test only asserted the handle's `Semantics.onTap` is non-null, so it would not catch a regression where the tap stops changing the sheet size — **FIXED**: the test now invokes the handle's `Semantics.onTap` and asserts `Expanded`/`Collapsed` plus the actual sheet-size transition (min ⇄ opening) both ways | post-fix `test/features/home/presentation/home_screen_test.dart:1315-1348`; toggle `features/home/presentation/home_screen.dart:342-352,677` | low | [home] |
| 24 | **Note (test migration, not a defect):** the driver `rate_sheet_test.dart` finder moved from `FilledButton` to a descendant `ElevatedButton` of the `rate-submit` key, because the shared `AppRatingSheet` renders the shared `AppButton` (`ElevatedButton`) instead of the old local `FilledButton`; behavior unchanged | `driver_app/test/features/rides/presentation/rate_sheet_test.dart:35-37`; shared `shared/lib/src/components/app_button.dart:83` | low | [rating] |
| 25 | **Test-audit follow-up (tracked, not a code defect):** rider widget tests pumped the real `HomeScreen`/`ActiveRideScreen`, whose `FlutterMap` built a live `NetworkTileProvider` against `tile.openstreetmap.org`, so the suite made real network requests. — **RESOLVED (absorbed)** by Landed `[map]`: the shared nullable `mapTileLayerProvider` seam now exists and the three mounting suites override it to `null` | `shared/lib/src/map/map_tile_layer.dart:21`; overrides `test/features/home/presentation/home_screen_test.dart:131`, `test/features/home/presentation/active_ride_screen_test.dart:300`, `test/features/navigation/rider_sidebar_test.dart:84`; audit `tests/AUDIT_REPORT.md:78-80` | low | [map] |
| 26 | **Test-audit follow-up — shared-owned (tracked, not a code defect):** `shared/test/network/websocket_service_test.dart` drove the heartbeat in real time (`waitFor` + fixed `Future.delayed`s) instead of `fakeAsync`, causing a documented flake. — **RESOLVED**: an additive `WebSocketTimerFactory` seam drives both the reconnect and heartbeat timers through a manual, deterministic factory while the production default stays the real `Timer` constructors (timing byte-for-byte unchanged). `fakeAsync` still cannot be used — the suite talks to a real `dart:io` socket, whose I/O never completes inside a fake-clock zone — so the manual-timer seam is the right determinism mechanism (documented in the suite). `shared/` has no `STATUS.md`, so it is recorded here as a shared-owned follow-up | seam `shared/lib/src/network/websocket_service.dart:11-25,84-86,163-172,184-191`; converted suite `shared/test/network/websocket_service_test.dart:8-15,16-74,96-108`; audit `tests/AUDIT_REPORT.md:81-83` | low | shared |
| 27 | **Note (test gap, not a code defect):** the rider shell back test exercised only `/profile`; all five non-home sections share the identical `isHome ? null : AppBar(leading: AppBackButton…)` branch, so the one widget test covered the branch but asserted no per-section case. — **FIXED** by `[test]_rider_coverage_gaps.md` (T3): the case is parameterized over all five sections, each asserting the back arrow + `AppBar` toggle and the tap returning to `home-body` | post-fix `test/features/navigation/rider_shell_test.dart:87-117`; shared branch `features/navigation/rider_shell.dart:85-93` | low | [test] |
| 28 | **Note (test gap, not a code defect):** the profile card's `nav-link-home` row was code-proven (fed the same list minus `profile`) but had no direct widget assertion — the shared `app_nav_link_card_test.dart` only asserted `nav-link-payment`/`nav-link-vehicle`. — **FIXED** by `[test]_rider_coverage_gaps.md` (T4/T5): the rider profile suite asserts `nav-link-home` present, `nav-link-profile` absent, the exact row set, and the Home row's `context.push('/home')` | post-fix `test/features/home/presentation/profile_screen_test.dart:350-381`; `features/home/presentation/profile_screen.dart:110-115`; `shared/test/navigation/app_nav_link_card_test.dart:108-109` | low | [test] |
| 29 | **Status chip lied after arrival:** `_getStatusText` had cases only for `driverApproaching`/`onTrip`/`completed` and `default: return 'Matching'`, so `driverArrived` (mapped correctly from backend `driver_arrived` at `ride_status_provider.dart:164-165`) and `matching`/`cancelled`/`noDriverAvailable`/`idle` all rendered the generic `Matching`. — **FIXED** by `[ontrip]_status_labels.md`: the switch is exhaustive with no `default` (each enum value has an explicit label) | post-fix `features/home/presentation/active_ride_screen.dart:1076-1096`; pre-fix `:786-797`; mapping `features/home/data/ride_status_provider.dart:158-177` | medium | [ontrip] |
| 30 | **ETA throttle bookkeeping leaked across rides (residual of `[ontrip]_driver_arrival_eta.md`):** `DriverEtaNotifier` is a global non-`autoDispose` provider and `stop()` only cancelled the tick — it never reset `_referenceFix`/`_lastRequestAt`, so the D4 "immediate on the first fix after entering `driverApproaching`" guarantee held only for the **session's first ride**. On a later ride the first compute was floored by the previous ride's `_lastRequestAt` (up to 5 s late) and the ≥150 m early trigger compared against a stale fix from the earlier ride. The R1 client compute and the request floor themselves are correct; only the per-ride reset was missing. — **FIXED** by `[ontrip]_eta_state_reset.md`: `_resetThrottle()` clears the reference at every boundary and bumps a ride/session `_generation` that gates any stale in-flight response | post-fix `features/home/data/driver_eta_provider.dart:93-98,116-122,149-169,186-201,219,233,239,243`; pre-fix `:82-88,131-134,243-246`; screen `stop()` on dispose `features/home/presentation/active_ride_screen.dart:140`; regression tests `test/features/home/data/driver_eta_provider_test.dart:281-419` | medium | [ontrip] |
| 31 | **Test gap (tracked, not a code defect):** the web-reload bootstrap fix was covered only at the unit level (`resolveRedirect` / `SessionBootstrap.run`) plus cold-start and post-login integration; there was **no** full-widget test that mounted `RiderApp`/the router at a reloaded shell location with a stored session to assert it lands on `HomeScreen`. The real browser reload is UNVERIFIABLE in this WSL harness. — **FIXED** by `[test]_rider_coverage_gaps.md` (T1/T2): a full-widget test mounts the real `RiderApp` booted at `/home` and asserts the reload window shows the splash spinner (never `LoginScreen`) and settles on `HomeScreen`; observed RED→GREEN against the `!bootstrapComplete` gate. **Honest scope limit:** the `routerInitialLocationProvider` seam does not discriminate on its own (booting at `/splash` vs `/home` converges because `resolveRedirect` funnels pre-bootstrap entries to `/splash`); T1's real teeth are the gate, and a real browser reload remains UNVERIFIABLE here | post-fix `test/features/auth/presentation/app_reload_test.dart:107,120-145`; seam `core/router/app_router.dart:25-28,33`; unit `test/core/router/app_router_test.dart:50-164`; bootstrap `test/app_bootstrap_test.dart:77-108` | low | [test] |
| 32 | **Home booking panel does not resize with a mouse on web/desktop:** the panel's only **pointer-drag** resize path was the internal scroll drag (the `Semantics` toggle/`animateTo` also resized, accessibility-only), but Flutter's default `ScrollBehavior.dragDevices` excludes `PointerDeviceKind.mouse`; the 48 dp handle was a `Semantics`-only toggle with no drag recognizer, so a mouse drag on it never reached `DraggableScrollableSheet`; touch on mobile worked. — **FIXED** by `[home]_panel_drag_desktop_web.md`: a platform-gated (`shouldEnableSheetDragHandle`) desktop/web-only grabber, keyed `home-sheet-handle`, with `behavior: HitTestBehavior.opaque` and `supportedDevices: {PointerDeviceKind.mouse}`, drives `_sheetController` and settles end **and** cancel on a fling-aware `{min, initial, max}` snap; mobile callbacks stay null so the touch/scroll path is unchanged; no physics change (the sheet controller already injects `AlwaysScrollableScrollPhysics`) | post-fix `features/home/presentation/home_screen.dart:737-772,364-422`, `core/platform/sheet_drag_handle.dart:5-21`; tests `test/core/platform/sheet_drag_handle_test.dart:5-43`, `test/features/home/presentation/home_screen_test.dart:1365-1663`; pre-fix `features/home/presentation/home_screen.dart` handle (old numbering `:661-664,665-687`) | medium | [home] |

*Rows #25–#26 track `tests/AUDIT_REPORT.md` §5.2–§5.3. Both are **resolved**: #25 by Landed `[map]`; #26 by the shared additive timer seam (2026-10-11). #26 is shared-owned (no shared `STATUS.md`).*

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[map]_self_hosted_tile_host.md` | map | `[]` — **deferred; gate met by Landed `[map]`** | **DEFERRED.** Stand up a self-hosted tile server and replace the OSM public host (values-only change to the shared `MapTileConfig`); removes third-party policy risk; infra + migration decisions recorded. Authored once in the rider domain; driver consumes. |
| `[map]_runtime_remote_tile_config.md` | map | `[]` — **deferred; gate met by Landed `[map]`** | **DEFERRED.** Fetch tile URL/key/attribution at runtime instead of compile-time `String.fromEnvironment`; shared factory unchanged; **compile-time default + last-good-cache fallback** so a config outage never blanks the map. The remote-config endpoint owner/shape is **UNSPECIFIED** (an open question to resolve only when scheduled, **not** an `api_plans` prerequisite). Authored once in the rider domain; driver consumes. |
| `[release]_app_id_and_store_readiness.md` | release | `[]` | **DEFERRED.** Finalize the real reverse-DNS `applicationId` for **BOTH** apps; update Android/iOS build files; align `MapTileConfig.userAgentPackageName` (must match the chosen id) in the same commit; signing/build config; store metadata/data-safety. Canonical file — the driver domain references it, does not duplicate. Until it lands `userAgentPackageName` tracks the stock `com.example.rider_app`/`com.example.driver_app`. |
| `[map]_current_location_button.md` | map | `[]` | **Rider Home + ActiveRide bottom-right locate/FAB:** first press fits the route (preview polyline or itinerary pins), later presses center on the resolved rider fix; authors the canonical shared `fitMapCamera`/`centerMapCamera` + `AppMapLocateButton` for the driver plan (`driver_app_plans/01_[map]_current_location_button.md`) to consume verbatim. No API change. |

The two `[map]` deferred plans are **siblings, not a chain**: both are alternatives/composables over
the same shared `MapTileConfig`, gated behind the now-landed `[map]` work (STATUS.md → Landed `[map]`).
They stay unnumbered with `depends_on: []` and carry `status: deferred` (numbering is reserved for
sequential stages; two same-tag branch heads cannot both be `01_`). Their gate is met; flip a plan's
`status` to `open` when its product trigger is chosen.

Earlier wave plans — `[tracking]_ride_detail_receipt_rating.md` (LC-3 + LC-4) and
`01_[ontrip]_live_route_and_eta.md` — landed, were condensed into Landed above, and were deleted
(2026-10-03). The most recent open plan, `[multi]_rider_stop_list_ui.md`, landed, was condensed into
Landed `[multi]` above, and was deleted (2026-10-06). `[home]_bottom_panel_resize.md` and
`[rating]_unify_rating_ui.md` landed, were condensed into Landed `[home]`/`[rating]` above, and
were deleted (2026-10-08). `[map]_android_tile_access.md` and `[location]_android_location_permission.md`
landed, were condensed into Landed `[map]`/`[location]` above, and were deleted (2026-10-08).
`[nav]_home_destination.md` and `[nav]_back_navigation.md` landed, were condensed into
Landed `[nav]` above, and were deleted (2026-10-08).
The 2026-10-13 wave — `[auth]_web_reload_session_bootstrap.md`,
`01_[trip]_post_auth_live_trip_restore.md`, `[ontrip]_status_labels.md`,
`[ontrip]_active_trip_itinerary.md`, `[ontrip]_driver_arrival_eta.md` and
`01_[arrival]_auto_arrival_nearby.md` — landed, were condensed into Landed
`[auth]`/`[trip]`/`[ontrip]`/`[arrival]` above, and were deleted (2026-10-13).
The 2026-10-15 bug-fix wave — `[ontrip]_eta_state_reset.md` (bug #30) and
`[test]_rider_coverage_gaps.md` (bugs #31/#27/#28) — landed, were condensed into Landed
`[ontrip]`/`[test]` above, and were deleted (2026-10-15).

## Invariants

- Keep the re-export-shim structure intact: never move app files into `shared/`, only ADD code there.
  New shared symbols are imported from the barrel directly — do **not** add shims for them.
- `shared/` holds no route table and no `go_router` dependency: route strings and navigation
  callbacks are owned by the app (see the `[nav]` Landed entry above).
- **`shared/` deliberately depends on `flutter_map` (owner decision, 2026-10-06).** The single tile
  code path — `MapTileConfig` (`shared/lib/src/map/map_tile_config.dart`), `buildMapTileLayer` +
  `mapTileLayerProvider` (`shared/lib/src/map/map_tile_layer.dart`) and `MapTileAttribution`
  (`shared/lib/src/map/map_tile_attribution.dart`) — lives in shared so the rider and driver apps
  cannot drift. This is an explicit exception to the "shared is dependency-light" spirit; it does
  **not** relax the re-export rule (no shims for these symbols).
- **One tile source of truth.** No app screen may name a tile host, `userAgentPackageName`, a browser
  `User-Agent`, or a tile API key. Apps build a `MapTileConfig` from `MAP_TILE_URL`/`MAP_TILE_API_KEY`
  and render through the shared factory. The UA must be truthful and contact-bearing (never a desktop
  browser string), in the exact form `<app>/<version> (+contact: <email>)`, and
  `userAgentPackageName` must be the real `com.example.*` application id (finalized by
  `[release]_app_id_and_store_readiness.md`; the UA contact placeholder `tiles@example.invalid` must be
  replaced before release). OSM (or the chosen provider) attribution must be visible via
  `MapTileAttribution`.
- **Shared background tracking is a shared artifact, not an app one.** A future Android background
  tracking service — and the additive, opt-in `LocationHelper` extension it needs — belongs in
  `shared/lib/src/location/` and is barrel-exported for both apps, so the rider and driver cannot
  diverge. It is owned/designed by `driver_app_plans/[location]_background_tracking.md`; this domain
  only records the ownership/shared boundary and keeps rider behavior foreground-only (no
  `ACCESS_BACKGROUND_LOCATION`). Not designed in the landed `[map]` work, which only notes the
  handoff.
- **The shell owns the only `Scaffold` on the six section routes.** Section screens are body-only.
  In particular the rider settings screen composes the shared `AppSettingsSection`/`AppSettingsRow`
  rows directly rather than reusing the shared `AppSettingsScreen`, because `AppSettingsScreen`
  hardcodes its own `Scaffold`/`AppBar` and nesting it would render two app bars. Any new shared
  full-screen widget intended for the shell must likewise be body-only (or expose a body-only
  variant).
- **The rider shell owns the back affordance on the sections.** The five non-home sections render
  `AppBackButton(onFallback: () => context.go('/home'))` as the shell `AppBar` `leading`, with the
  `AppSidebarToggleButton` in `actions`; `/home` stays edge-to-edge (no `AppBar`, its toggle is the
  `Positioned` overlay); `/login` and `/splash` stay roots with no back. `shared/` owns no router —
  `AppBackButton` pops if it can and otherwise calls the app-supplied `onFallback`, never `go`/`push`
  (`shared/lib/src/navigation/app_back_button.dart:41-49`).
- Tests use `mocktail` + `http_mock_adapter`, mirroring the existing suites.
- Don't remove public providers used by other screens; extend them.
- The API never answers an outage with 4xx: it answers 5xx or `200 is_estimate: true`. Since
  `[map]_route_failure_honesty.md` the Home preview draws **no** polyline on *any* error status
  (`home_route_preview.dart:72-94`; `home_screen.dart:210-222`), so a misclassified 4xx can no longer
  render a fake route — but the error contract (and the active trip) still require it.
- **The active trip never draws a confident road-less route.** `TripRouteState.unavailable` carries
  no polyline and the screen renders only the "Route unavailable" banner; `isEstimate` is grey +
  dashed behind an explicit banner; solid blue is reserved for `ready`
  (`active_ride_screen.dart:420-466`). An `etaSeconds` of `300` is "unknown", never a rendered ETA
  (`trip_eta.dart:5`).

### Skip list (backend STUB / delivery inert — do NOT build UI) — authoritative

| Area | Endpoints | Why skip |
|---|---|---|
| Payment methods | `GET/POST/DELETE /rider/payment-methods` | all STUB (`StubPayment`) — keep `PaymentScreen` placeholder |
| Tipping | `POST /rides/:id/tip` | STUB |
| Promotions | `GET /promotions`, `POST /promotions/apply` | STUB (empty list / ack) |
| Place details/geocode | `GET /places/geocode`, `GET /places/details` | STUB (`{"place":null}`) |
| Analytics | `GET /geo/isochrone`, `GET /heatmap` | STUB/placeholder |
| Devices/push | `POST /devices`, `DELETE /devices/:token` | endpoints real (rider registration seam landed — see Landed `[push]`); delivery inert (no FCM/APNs provider), no rider UI to build |
| Feedback | `POST /feedback` | ack only |
| Social/verify | `POST /auth/social`, `verify-email`, `verify-phone` | STUB/PARTIAL (code ignored) |
| Destination change | `PUT /rides/:id/destination` | **Not a stub** — real mutation landed in `api_plans [multi]` (`internal/service/ride.go:530-540`), and the rider UI landed `[multi]` (see Landed): `change_destination_provider.dart` + `active_ride_screen.dart:745-770` |
| Driver side | all `/driver/*` + `ride.accept`/`ride.decline` | different role/app |

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

Landing — `[home]_panel_drag_desktop_web.md` (bug #32) + `01_[tracking]_cancel_single_flight.md`,
2026-10-19: both plans were adversarially verified — the Home panel implementation and the rider
single-flight cancel were each **CONFIRMED** (the Home review also prompted the test hardening now in
the tree: mouse-only `supportedDevices`, cancel settle, fling direction). Both plans are condensed
into Landed `[home]`/`[tracking]` above, their files were deleted, bug #32 is **FIXED**, and both
Open-plans rows were removed (the `[map]_current_location_button.md` row is retained). Gates were
independently run immediately before landing (not re-run by this condensation): `melos run analyze`
clean; `melos run test` green — rider **473**, driver **451**, shared **205 + 1 skipped** (Linux FVM
SDK + native Melos 8). **UNVERIFIABLE in this WSL harness:** real browser/desktop mouse behavior (the
widget suite proves the recognizer drives the controller, including cancel and fling). Dangling-
`depends_on` check re-run after deleting the cancel plan: the cancel plan's
`api_plans/[rides]_cancel_accept_race.md` dependency disappears with it; the surviving
`[map]_current_location_button.md` is `[]`, the two deferred `[map]` siblings are `[]`, and the
deferred `[release]` plan is `[]` — no dangling reference in the rider domain. No driver/api file was
edited.

Landing — `[ontrip]_eta_state_reset.md` (bug #30) + `[test]_rider_coverage_gaps.md`
(bugs #31/#27/#28), 2026-10-15: both plans were adversarially verified and **CONFIRMED-LANDED**.
For #30 the reviewer independently reproduced RED→GREEN by mutation (removing the reset / the
generation guard makes the regression tests fail) and confirmed the within-ride 5 s floor, 150 m
trigger and `300 == unknown` honesty are untouched; for #31 the reviewer independently reproduced
RED→GREEN by removing `resolveRedirect`'s `!bootstrapComplete` gate and confirmed the T1 seam's
non-discriminating scope limit. Both plans were condensed into Landed `[ontrip]`/`[test]` above and
their files were deleted; bugs #27/#28/#30/#31 are marked FIXED and their Open-plans rows removed.
Gates: the tree was verified green immediately before landing — `melos run analyze` clean across all
three packages; `melos run test` rider **452**, driver **408**, shared **205 passed + 1 skipped**
(Linux FVM SDK + native Melos 8; `melos` was not re-run by this condensation). One rider claim stays
**UNVERIFIABLE in this WSL harness**: a real browser reload (close with `flutter run -d chrome` → sign
in → navigate to `#/home` → hard reload → assert Home, not login). Dangling-`depends_on` check re-run:
all three survivors (`[map]_self_hosted_tile_host.md`, `[map]_runtime_remote_tile_config.md`,
`[release]_app_id_and_store_readiness.md`) have `depends_on: []` — no dangling reference.

(`make flutter-analyze`/`make flutter-test` are broken from this WSL tree — they shell out to the
Windows `melos.bat` through `cmd.exe`, which cannot `cd` into the UNC path. Native Melos 8 is at
`~/.pub-cache/bin/melos`.)

Last wave (`[map]_route_failure_honesty.md`, 2026-10-05): rider 298 tests green, `melos run analyze`
clean (Linux FVM SDK + native Melos 8). Earlier wave (LC-3 + LC-4 + `[ontrip]`, 2026-10-03): rider
274 tests green. Landing claims adversarially reviewed before condensing.

`[push]` condensation (2026-10-06): static `file:line` evidence verified; 15 unit tests present
(`test/core/push/device_token_service_test.dart`). Runtime `melos run analyze` / `melos run test`
were **not** re-run during this condensation (UNVERIFIABLE here) — run them to close.

`[history]` rated-seed condensation (2026-10-05): static `file:line` evidence verified and the
superseded `[tracking]` seed-walk citation refreshed; the API `ride_id` prerequisite is landed
(`api_plans/STATUS.md` → Landed `[history]`). Runtime `melos run analyze` / `melos run test` were
**not** re-run during this condensation (UNVERIFIABLE here) — the implementing agent reports rider
319 / driver 323 / shared 151 green; run them to close.

`[multi]` stop-list condensation (2026-10-06): static `file:line` evidence verified against the
post-landing tree and the moved `[map]` Home-preview citations refreshed. `flutter analyze` on the
five touched sources is clean, and `flutter test` on the six relevant files
(`stop_list_test`, `multi_leg_route_provider_test`, `change_destination_provider_test`,
`home_screen_test`, `active_ride_screen_test`, `home_provider_test`) passed 74/74 (Linux FVM SDK).
The implementing agent reports the full suite rider 347 / driver 337 / shared 151 green; the full
`melos run test` was **not** re-run here. A concurrent `antagonistic-reviewer` verdict was still in
flight at condense time; this entry records only what the code shows and does not pre-empt it.

Map/location plan grooming (2026-10-06, product-owner locked decisions): `[map]_android_tile_access.md`
and `[location]_android_location_permission.md` were rewritten to replace their open questions with the
locked decisions, and two deferred `[map]` plan files were authored
(`[map]_self_hosted_tile_host.md`, `[map]_runtime_remote_tile_config.md`). **Plan-only change — no
source, manifest or test was edited, and `melos run analyze`/`melos run test` were not run.** All rider
`depends_on` targets resolve (checked; all `[]`) — no dangling `depends_on`.

Remaining product-owner decisions applied (2026-10-06): the locked UA format
(`<app>/<version> (+contact: <email>)`) plus the `tiles@example.invalid` placeholder and a pre-release
checklist landed in `[map]_android_tile_access.md`; `[map]_runtime_remote_tile_config.md` no longer
requires an `api_plans` endpoint (owner/shape UNSPECIFIED, deferred); a new deferred
`[release]_app_id_and_store_readiness.md` was authored (final `applicationId` + `userAgentPackageName`
alignment + signing/store, canonical, driver references it); and the shared background-tracking service
handoff was recorded (invariant above + the map plan's forward note/Cross-domain). **Plan-only — no
source edited; checks re-run below.**

`[fare]` waypoint-fare condensation (2026-10-08): static `file:line` evidence verified against the
post-landing tree (rider + API). Gates (independently run, 2026-10-08): `melos run analyze` clean;
`melos run test` green — rider **350 passed** (was 347), driver 337, shared 151 (Linux FVM SDK +
native Melos 8). The API half landed (`api_plans/STATUS.md` → Landed `[fare]`; waypoint-aware booking
quote + `POST /estimates/price` with a `stops` body). Dangling-`depends_on` check re-run: every
rider plan's `depends_on` is `[]` — no dangling reference.

Product-owner decision lock + link hygiene (2026-10-08): the six open plans (`[location]`,
`[auth]`, `[trip]`, `[rating]`, `[design]`, `[home]`) replaced their "Open product decisions surfaced"
sections with `## Locked product decisions (2026-10-08 — product owner)`, and their bodies were
reconciled where they contradicted a lock (rating `allowComment: true` + one bottom sheet; design driver
counterpart filename; home max / no-second-recognizer / FAB). Dead links to the deleted fare
waypoint plan were re-pointed to `api_plans/STATUS.md` → Landed `[fare]` (Landed
`[fare]`, bug #13, condensation note); the `[location]` plan's stale `STATUS.md:318` citation now names
the Skip list row. Known bug #17 tracks the `ride_estimate_sheet_test.dart` gap for the `is_estimate`
caption / per-leg breakdown. **Plan-only — no source, test or manifest edited; `melos` not run here.**

`[location]` + `[trip]` pickup condensation (2026-10-08): static `file:line` evidence verified
against the post-landing tree; the runtime behavior was adversarially reviewed and **CONFIRMED** (no
fabricated location, pickup precedence / clearing / memory lifecycle / no-clobber / all four exit
intents correct). Gates independently run: `melos run analyze` clean; `melos run test` green — rider
**371 passed** (was 350), driver 337, shared 151 (Linux FVM SDK + native Melos 8). Both landed plan
files were deleted and their Open-plans rows removed. Dangling-`depends_on` check re-run: every
remaining rider plan's `depends_on` is `[]` — no dangling reference.

`[design]` shared-style-system condensation (2026-10-08): static `file:line` evidence verified
against the post-landing tree; the four landing claims were adversarially reviewed and
**CONFIRMED-LANDED**. Gates re-run independently by the reviewer: `melos run analyze` clean;
`melos run test` green — rider **363**, driver **302**, shared **165** (Linux FVM SDK + native
Melos 8; `melos` was not re-run by this condensation). The landed plan file was deleted and its
Open-plans row removed; the deliberate `AppMotion`/`AppBadge` zero-consumer deferral is recorded in
Landed `[design]`. Known bugs #18/#19 were fixed by this batch and are marked FIXED.
**Driver test count note:** the driver suite is **302**, down from the previously recorded **337** —
this is **NOT** a regression from `[design]` (the driver half is a separate plan,
`driver_app_plans/[design]_shared_style_adoption.md`, and `driver_app/lib` was not touched here).
The drop is a concurrent, documented test-audit deduplication process in progress
(`tests/AUDIT_REPORT.md`); it is unrelated to this batch. Dangling-`depends_on` check re-run: every
remaining rider plan's `depends_on` is `[]` — no dangling reference.

`[location]` bug #20 fix (2026-10-08): the destination/stop search no longer degrades with neither a
device fix nor a manual pickup — the destination field pushes unconditionally with a `_searchBias()`
center and `_addStop` always supplies one, so the biased search never hits the blocking guard, while
`_routePlan`/`canRequest` still refuse to fabricate a location. Adversarially reviewed and
**FIXED**. Gates (rider + shared + driver suites re-run live): `melos run analyze` clean;
`melos run test` green — rider **366** (up from 363), driver **302**, shared **165**
(Linux FVM SDK + native Melos 8). Bug #20 marked FIXED; the residual mid-trip change-destination
omission is tracked as the new bug #21, and the tautological `home_screen_test.dart:1097`
`findsNothing` assertion (the test route is a `SizedBox` stub, so the real-screen guarantee rests on
`location_search_screen_test.dart:61`) is tracked as the new bug #22. Plan-only / docs change — no
source or test edited here.

`[rating]` + `[home]` condensation (2026-10-08): static `file:line` evidence verified against the
post-landing tree; both landing claims adversarially reviewed and **CONFIRMED-LANDED**. Gates
re-run independently by the reviewer: `melos run analyze` clean; `melos run test` green twice —
rider **371**, driver **302**, shared **174** (Linux FVM SDK + native Melos 8; `melos` was not
re-run by this condensation). A one-off shared-suite flake the implementer saw did **not**
reproduce across the reviewer's 8 runs. Both landed plan files were deleted and their Open-plans
rows removed; the `[design]` `AppMotion` zero-consumer deferral was updated because `[home]` now
consumes it. The `[home]` handle-toggle test gap is tracked as bug #23 and the driver
`rate_sheet_test.dart` `FilledButton`→`ElevatedButton` finder migration as note #24.
Dangling-`depends_on` check re-run: every remaining rider plan's `depends_on` is `[]` — no
dangling reference.

`[location]` bug #21 fix (2026-10-08): mid-trip change-destination search no longer drops its
`lat`/`lng` bias — `_changeDestination` always pushes `_searchBias()` (trip pickup → rider
position → map center → default) as a search center only, and `PUT /rides/:id/destination`
still sends just the picked `place`, so no location is fabricated. Adversarially reviewed and
**FIXED**. Gates (rider tests re-run live): `melos run analyze` clean; `melos run test` green —
rider **372** (up from 371), driver **302**, shared **174** (2026-10-08; Linux FVM SDK + native
Melos 8). Bug #21 marked FIXED; bug #22 extended to the same-class tautological
`active_ride_screen_test.dart:1164` `findsNothing`. **Docs-only change — no source or test
edited here.** Dangling-`depends_on` check re-run: every rider plan's `depends_on` is `[]` — no
dangling reference.

`[map]` + `[location]` Android tile/location condensation (2026-10-08): static `file:line` evidence
verified against the post-landing tree; both landing claims adversarially reviewed and
**CONFIRMED-LANDED**. Gates re-run independently: `melos run analyze` clean; `melos run test` green —
rider **373**, driver **302**, shared **182** (2026-10-08; Linux FVM SDK + native Melos 8; `melos`
was not re-run by this condensation). Both landed plan files were deleted and their Open-plans rows
removed. Known bugs #14/#15 (Android release network + OSM "Access Blocked") and #16 (Android location
permission) are **FIXED**; test-audit bug #25 is **RESOLVED (absorbed)** by the shared nullable
`mapTileLayerProvider` seam. Bugs #17/#22/#23 remain open (B5.2 test-hardening work).
**Plan↔code drift:** `[map]` specified `APP_VERSION` `defaultValue: 'dev'`; the landed/fixed code uses
`'1.0.0'` (restores the Settings footer version), guarded by
`test/features/settings/presentation/settings_screen_test.dart:59-69`. The rider tile provider also
passes a real ops contact (`ricardoapuch@gmail.com`) rather than shipping `MapTileConfig.defaultContact`
(`tiles@example.invalid`), so the rider UA is contact-bearing now; the shared placeholder remains the
default for callers that do not override it.
**UNVERIFIABLE in this WSL tree:** the Android on-device/manifest symptoms. Close on an Android host
with `flutter build apk --release` then inspect the **merged** manifest for
`INTERNET`/`ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` +
`uses-feature android.hardware.location.gps required="true"` (and the absence of
`ACCESS_BACKGROUND_LOCATION`), install and confirm tiles render (not "Access Blocked") with visible
attribution, the OS permission dialog appears and a fix is obtained, and a ride request reaches the
API — and temporarily mock/capture the tile host to assert the outbound UA is exactly
`rider_app/1.0.0 (+contact: ricardoapuch@gmail.com)` (never the desktop Chrome string), names
`com.example.rider_app`, and contains no `tiles@example.invalid`. Dangling-`depends_on` check re-run:
every remaining rider plan's `depends_on` is `[]` — no dangling reference. The two deferred `[map]`
siblings' prose gates were re-pointed at Landed `[map]` (STATUS.md) instead of the deleted file.
**Driver-domain drift (report only, not touched):** `driver_app_plans/[map]_android_tile_access.md`
and `driver_app_plans/[location]_android_location_permission.md` still reference the deleted rider
plan filenames; the driver domain must re-point those at Landed `[map]`/`[location]`.

`[nav]` Home-destination + back-navigation condensation (2026-10-08): static `file:line` evidence
verified against the post-landing tree; both landing claims adversarially reviewed and
**CONFIRMED-LANDED**. Gates re-run: `melos run analyze` clean; `melos run test` green — rider
**384**, driver **302**, shared **189** (2026-10-08; Linux FVM SDK + native Melos 8; `melos` was
not re-run by this condensation). Both landed plan files were deleted and their Open-plans rows
removed. The two code-proven-but-untested gaps are recorded as notes #27 (shell back test only
exercises `/profile`) and #28 (profile card `nav-link-home` row has no direct widget assertion).
Dangling-`depends_on` check re-run: every remaining rider plan's `depends_on` is `[]` — no
dangling reference.

`[auth]` Enter-to-submit condensation (2026-10-08): static `file:line` evidence verified against the
post-landing tree; the Enter-to-login landing claim was adversarially reviewed and **CONFIRMED** (one
`_submit()` path, mobile stays `null`, `_isSubmitting` guard). Gates independently re-run:
`melos run analyze` clean; `melos run test` green — rider **394**, driver **302**, shared **189**
(2026-10-08; Linux FVM SDK + native Melos 8; `melos` was not re-run by this condensation). The
landed plan file was deleted and its Open-plans row removed. Bugs **#17** and **#23** were
adversarially reviewed and **CONFIRMED-FIXED**; bug **#22** is **CONFIRMED-CLOSED** (mutation-proven
— flipping the production guard makes the new negative-control assertion fail). Dangling-`depends_on`
check re-run: every remaining rider plan's `depends_on` is `[]` — no dangling reference.
**Citation drift (report only):** the landing brief put the #17 evidence at
  `ride_estimate_sheet_test.dart:224-274` and #23 at `home_screen_test.dart:1318-1351`; the verified
  ranges are `:225-263` (file ends at 264) and `:1315-1348` respectively, and those are what this file
  records.

`[auth]` web-session-persistence condensation (2026-10-08): static `file:line` evidence verified
against the post-landing tree; the eight behavioral claims were adversarially reviewed and
**CONFIRMED** (Chrome web test 4/4), after which two residual drifts were fixed (a storage-read-throw
+ 401 wipe vector, and the untested `onLoggedOut()` hook). Gates independently run:
`melos run analyze` clean; `melos run test` green — rider **394**, driver **316**, shared
**205 passed + 1 skipped** (2026-10-08; Linux FVM SDK + native Melos 8; `melos` was not re-run by this
condensation). The one skip is the browser-only `window.localStorage` case
(`shared/test/auth/auth_storage_test.dart:93-104`), so that specific claim is **verified on Chrome**
via `flutter test --platform chrome` from `shared/` — not by the VM suite. The shared websocket suite
has a pre-existing real-time flake (recorded as bug #26) and is unrelated to this batch. The landed
plan file was deleted and its Open-plans row removed. Dangling-`depends_on` check re-run: every
remaining rider plan's `depends_on` is `[]` — no dangling reference.
**Citation drift (report only):** the landing brief's line numbers predate the two post-review fixes
(`app_auth_controller.dart` was edited after the review), so the brief's `_isDefinitiveAuthFailure`
`:128-137`, `checkAuth` `:139-196`, `refreshToken` `:387-388`, `_clearLocalSession` `:244-255` and
`login` `:328-338` are stale; the verified ranges recorded in Landed `[auth]` above
(`:135-144`, `:146-204`, `:397-398`, `:254-265`, `:340-348`) are current. The `readFailed` tuple
  `:22,403-409,228-236` also drifted by one to `:22,403-410,228-237`.

Flutter test-hygiene cleanup (2026-10-11): the shared websocket suite's real-time heartbeat
flake (bug #26) is **RESOLVED**. The additive `WebSocketTimerFactory` seam
(`shared/lib/src/network/websocket_service.dart:11-25,84-86,163-172,184-191`) defaults to the real
`Timer` constructors, so production timing is unchanged; the converted
`shared/test/network/websocket_service_test.dart` exercises the real `dart:io` socket but drives
both the reconnect and heartbeat timers through a manual, deterministic factory. `fakeAsync` cannot
be used here because real I/O never completes in a fake-clock zone; the manual-timer seam is the
appropriate mechanism and is documented in the suite. The landing claim was adversarially reviewed
and **CONFIRMED-LANDED**. Gates: `melos run test` green across 3 consecutive full runs with no flake
— shared **205 passed + 1 skipped** now (was 189/203 in earlier waves; the one skip is the
browser-only `window.localStorage` case, `shared/test/auth/auth_storage_test.dart:93-104`, verified
on Chrome), rider **394**, driver **317** (2026-10-11; Linux FVM SDK + native Melos 8; `melos` was
not re-run by this condensation). Bug #25 remains resolved by Landed `[map]`. Dangling-`depends_on`
check re-run: every remaining rider plan's `depends_on` is `[]` — no dangling reference.

Condensation — X2-R/X1-R/X3-R + R-1/R-2/R-3 (2026-10-13): all six landings were implemented on the
post-2026-10-11 tree and adversarially re-reviewed. **Landed:** the `[auth]` web-reload bootstrap
(`checkAuth()` once on every entry path + a bootstrap-gated `redirect`), the `[trip]` post-auth
live-trip restore (`resolvePostAuthRoute`, `pending` counts, dead `restore()` deleted), the
`[ontrip]` exhaustive status labels (bug #29 fixed) and the active-trip itinerary/change-destination
confirmation, the `[ontrip]` live driver-arrival ETA (R1), and the `[arrival]` nearby/auto-arrival
consumption. `melos run analyze` clean; `melos run test` green — rider **441**, shared **205 passed
+ 1 skipped**, driver **353** (implementer-reported 2026-10-13; Linux FVM SDK + native Melos 8). The
one skip is the browser-only `window.localStorage` case; the real browser reload is **UNVERIFIABLE**
in this WSL harness. The residual per-ride ETA-throttle leak and the missing full-widget web-reload
test are recorded as bugs #30/#31. Dangling-`depends_on` check: the survivors are the two
deferred `[map]` siblings (`depends_on: []`) and the deferred `[release]` plan (`depends_on: []`),
plus the two bug-fix plans then authored with non-empty `depends_on` naming **landed capability only**
(`[ontrip]_eta_state_reset.md` → Landed `[ontrip]`; `[test]_rider_coverage_gaps.md` → Landed
`[auth]`/`[nav]`) — no dangling reference. (Both were subsequently landed 2026-10-15.)
Reported (not authored): the driver-app mirrors for the web-reload defect and
the post-auth restore belong to `driver-planner`; the possible `api_plans` follow-up (whether a
confirmed change-destination estimate becomes the booked quote) remains an open input.

Bug-fix plan authoring + landing (2026-10-15): the two reviewed rider bug-fix plans —
`[ontrip]_eta_state_reset.md` (tag `ontrip`, unnumbered; bug #30) and
`[test]_rider_coverage_gaps.md` (tag `test`, unnumbered; bugs #31/#27/#28) — were authored from the
2026-10-13 audit and then landed the same day (see the Landing note under Verification and Landed
`[ontrip]`/`[test]` above; both files deleted). **Cross-domain:** the deferred
`api_plans/[push]_production_provider.md` (`[push]`, `status: deferred`) is the one canonical push
plan; its §Scope item 3 owns the real-FCM/APNs token source, referencing the rider registration half
(`Landed [push]` above) by path rather than duplicating it.
