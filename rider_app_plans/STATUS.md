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

### [trip]
- Pre-trip pickup recovery after a trip ends — global `pickupMemoryProvider` (`PickupMemory` with `remember`/`markReturning`/`consumeReturn`/`clear`) survives `HomeScreen` disposal `features/home/data/pickup_memory_provider.dart:6,26,34,43,50`, with the centralized `markTripReturn`/`resetRideState` exit helper `features/home/data/trip_return.dart:9,22`; Home consumes the return intent in `initState` and post-frame resets state / restores the manual `Place` / re-fits (`features/home/presentation/home_screen.dart:74-103`); cancel + no-driver exits mark `restore: true` (`driver_matching_screen.dart:61-65`, `active_ride_screen.dart:194,381-386,463`) and completion marks `restore: false` (`active_ride_screen.dart:372-375`); logout clears the memory (`core/auth/auth_provider.dart:79-81`). Tests `test/features/home/data/pickup_memory_provider_test.dart` (5), extended home/matching/active-ride suites.

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

### [home]
- Resizable Home booking panel (drag/scroll + snap; the map really shrinks) —
  `features/home/presentation/home_screen.dart`: session-only `homePanelSizeProvider` `:22`,
  `DraggableScrollableController` `:71`, `snap: true` + content-driven max capped `0.9`
  `:356-369,543-551`, the map's layout box shrinks via `AnimatedBuilder` + `SizedBox('home-map')`
  `:393-404`, `_fitItinerary` bottom padding tracks the panel `:173-181`, FAB lifted above the
  panel `:517-531`, keyboard inset padding `:566`; the handle is a 48 dp `Semantics`
  min↔opening-size toggle with **no** `GestureDetector` `:663-689`. `[map]` honesty / single
  booking path / `StopList` `NeverScrollableScrollPhysics` invariants intact. Tests
  `test/features/home/presentation/home_screen_test.dart` (+5, `:1183-1308`).

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
| 14 | **Android release build has no network:** `android.permission.INTERNET` is declared only in the debug/profile manifests, so a release APK has no tiles, API or WS at all (stock Flutter template behaviour, but a shipping bug here). Fix locked (2026-10-06): add `INTERNET` to the main manifest | `rider_app/android/app/src/main/AndroidManifest.xml:1-45` (absent); `src/debug/AndroidManifest.xml:6`; `src/profile/AndroidManifest.xml:6` | high | [map] |
| 15 | **Android maps show OSM "Access Blocked":** both maps send a hardcoded spoofed desktop Chrome `User-Agent`; because `NetworkTileProvider(headers:)` already carries that key, flutter_map's `tile_layer.dart:299-300` `putIfAbsent` never injects `userAgentPackageName`, so OSM blocks the browser-spoofed app traffic. `userAgentPackageName: 'com.rider.app'` also mismatches the real `applicationId` `com.example.rider_app`. Fix locked (2026-10-06): OSM-compliance now — drop the spoofed UA, send a truthful contact-bearing UA, use the real package id, and de-dup both maps through the **fully shared** tile factory + shared attribution widget | `features/home/presentation/home_screen.dart:196-205`; `features/home/presentation/active_ride_screen.dart:476-484`; `rider_app/android/app/build.gradle.kts:18`; flutter_map 7.0.2 `tile_layer.dart:299-300` | high | [map] |
| 16 | **Android `geolocator` throws "No location permissions are defined in the manifest":** the main manifest declares neither `ACCESS_FINE_LOCATION` nor `ACCESS_COARSE_LOCATION`, so Home's `_initLocation`, the rider-location ping and the live-trip position stream all fail on Android. Fix locked (2026-10-06): add FINE+COARSE + `uses-feature gps required="true"`; no background location; no minSdk change; the `deniedForever` deep-link is handed to the `[location]` fallback (since landed — see Landed `[location]`) | `rider_app/android/app/src/main/AndroidManifest.xml:1-45`; `shared/lib/src/utils/location_helper.dart:4-23`; `features/home/presentation/home_screen.dart:147-172` | high | [location] |
| 17 | **Test gap (tracked, not a code defect):** `rider_app/test/features/home/presentation/ride_estimate_sheet_test.dart` has no case for the Landed `[fare]` `is_estimate` caption (`Estimated fare — not fully road-routed`) or the informational per-leg breakdown; both sheet/model paths are implemented but untested there | `features/home/presentation/ride_estimate_sheet.dart:106-111,154-180`; `features/home/model/ride_estimate.dart:7,46,50,81-91` | low | [fare] |
| 18 | Comment/condition drift (not a runtime defect): `_showLocationNotice`'s doc claimed the persistent notice required the rider "has not chosen a pickup", but the condition omits `_pickupLocation == null` — **FIXED** by `[design]`: the doc now states the notice persists after a manual pickup and clears only when a device fix arrives, matching the condition | `features/home/presentation/home_screen.dart:567-569` (comment) vs `:570-573` (condition) | low | [location] |
| 19 | **Test gap (tracked, not a code defect):** `[location]`/`[trip]` widget-coverage holes — the settings-action dispatch (`openAppSettings`/`openLocationSettings`) was never invoked from the widget, the restored pickup's route/estimate coordinates were not asserted, and the `remember(_pickupLocation)` call-site was untested — **FIXED** by `[design]`: three new cases add the settings-action dispatch, the restored-pickup route/estimate coordinates, and the `remember` call-site | `features/home/presentation/home_screen.dart:423,441,570-634,764`; tests `test/features/home/presentation/home_screen_test.dart:815-849,851-927,929-991` | low | [location]/[trip] |
| 20 | Destination/stop search still degraded when there is neither a device fix nor a manual pickup: the destination field's `origin == null` guard showed `Could not determine your location` and `_addStop` omitted `lat`/`lng`, so `LocationSearchScreen` short-circuited — **FIXED**: the destination field `onTap` unconditionally pushes with `_searchBias()` (`:465-485`); `_addStop` always supplies `lat`/`lng` (`:173-180`); the biased search never hits the `'Enable location to search nearby'` guard (`location_search_screen.dart:48-52,66-67`); and no location is fabricated — `_routePlan` still requires pickup/fix+destination (`:155-167`) and `canRequest` still requires pickup/fix (`:690-692`) | post-fix `features/home/presentation/home_screen.dart:465-485,173-180,155-167,690-692`; `features/home/presentation/location_search_screen.dart:48-52,66-67`; pre-fix `home_screen.dart:479-488,169-180`; tests `test/features/home/presentation/home_screen_test.dart:1022-1060,1062-1099,1101-1156` | low | [location] |
| 21 | Residual same-class gap (not covered by #20): **mid-trip change-destination** still omits `lat`/`lng` when `_searchOrigin()` is null, so the generic `/location-search` can still show the blocking `'Enable location to search nearby'` branch from that surface | `features/home/presentation/active_ride_screen.dart:206-213` (`if (origin != null)` guards on `lat`/`lng`) | low | [location]/[trip] |
| 22 | **Test gap (tracked, not a code defect):** `home_screen_test.dart:1097` `findsNothing('Enable location to search nearby')` is tautological — the test route is a `SizedBox` stub (`:190`), so the string could never render there anyway; the real-screen guarantee rests on `location_search_screen_test.dart:61`, so this assertion should be strengthened later | `test/features/home/presentation/home_screen_test.dart:1097` vs the stub route `:185-193`; real-screen coverage `test/features/home/presentation/location_search_screen_test.dart:61` | low | [location] |
| 23 | **Test gap (tracked, not a code defect):** the `[home]` handle-toggle test only asserts the handle's `Semantics.onTap` is non-null — it never invokes the toggle, so it would not catch a regression where the tap stops changing the sheet size | `test/features/home/presentation/home_screen_test.dart:1301-1307`; toggle `features/home/presentation/home_screen.dart:342-352,677` | low | [home] |
| 24 | **Note (test migration, not a defect):** the driver `rate_sheet_test.dart` finder moved from `FilledButton` to a descendant `ElevatedButton` of the `rate-submit` key, because the shared `AppRatingSheet` renders the shared `AppButton` (`ElevatedButton`) instead of the old local `FilledButton`; behavior unchanged | `driver_app/test/features/rides/presentation/rate_sheet_test.dart:35-37`; shared `shared/lib/src/components/app_button.dart:83` | low | [rating] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[auth]_enter_to_login_desktop.md` | auth | `[]` | Web/desktop Enter-to-submit on the rider login password field via a pure `shouldSubmitOnEnter` predicate; mobile unchanged; additive `AuthTextField` keyboard params; no double-submit during an in-flight request. No API/shared change. |
| `[auth]_web_session_persistence.md` | auth | `[]` | Web cold-start session survival: `checkAuth` recovers via the refresh token and clears only on a definitive 401/400 (transient network/timeout/5xx keeps tokens); `refreshToken` is single-flight and never server-revokes on a transient failure; storage errors never escape `login`/`checkAuth`/`refreshToken`; web `AuthStorage` uses a conditional-import `localStorage` backend. Shared change consumed by both apps (driver counterpart references it). Flutter-only, no API change. |
| `[nav]_home_destination.md` | nav | `[]` | Home as a first-class shared destination: add `AppNavDestination.home` (`home`/`Home`/`Icons.home_outlined`) and a leading `AppNavSection.home('HOME')` (or first under `account`), prepend it to `buildRiderNavItems()` so the drawer **and** the profile `AppNavLinkCard` can reach `/home`; update the shared/rider parity suites. **CROSS-DOMAIN** — the driver plan adopts the same two shared symbols. No API change. |
| `[nav]_back_navigation.md` | nav | `[]` | A back affordance on every screen: a shared router-free `AppBackButton` (`onPressed`/`onFallback`, `Icons.arrow_back`; reconciled with the parallel driver plan), a shell-level back on the five non-home sections (recommended `leading → /home`, hamburger to `actions`), explicit backs on `/register`+`/forgot-password` → `/login`, `/location-search` standardization, and arrow/guard decisions for `/driver-matching` + `/active-ride`; `/home`, `/login`, `/splash` stay roots. **CROSS-DOMAIN** — the driver plan adopts `AppBackButton`. No API change. |
| `[map]_android_tile_access.md` | map | `[]` | **Android-only; LOCKED 2026-10-06.** Add `INTERNET` to the main manifest; OSM-compliance now — drop the spoofed desktop `User-Agent`, send a truthful UA in the exact form `<app>/<version> (+contact: <email>)` (rider `rider_app/…`, driver `driver_app/…`), use `userAgentPackageName` `com.example.rider_app` (finalized by `[release]`); **fully shared** tile factory (`shared/lib/src/map/map_tile_config.dart` + `map_tile_layer.dart` + `map_tile_attribution.dart`; `shared/` gains `flutter_map`) with a nullable provider test seam; render the **shared attribution widget** now; leave the optional `MAP_TILE_API_KEY` seam. UA contact ships as the placeholder `MapTileConfig.defaultContact = 'tiles@example.invalid'` — **must not ship** (Pre-release checklist). Defines the canonical shared contract the driver adopts (co-owned); records the shared-background-service handoff. |
| `[map]_self_hosted_tile_host.md` | map | `[]` — **deferred; gated on `[map]_android_tile_access.md`** | **DEFERRED.** Stand up a self-hosted tile server and replace the OSM public host (values-only change to the shared `MapTileConfig`); removes third-party policy risk; infra + migration decisions recorded. Authored once in the rider domain; driver consumes. |
| `[map]_runtime_remote_tile_config.md` | map | `[]` — **deferred; gated on `[map]_android_tile_access.md`** | **DEFERRED.** Fetch tile URL/key/attribution at runtime instead of compile-time `String.fromEnvironment`; shared factory unchanged; **compile-time default + last-good-cache fallback** so a config outage never blanks the map. The remote-config endpoint owner/shape is **UNSPECIFIED** (an open question to resolve only when scheduled, **not** an `api_plans` prerequisite). Authored once in the rider domain; driver consumes. |
| `[release]_app_id_and_store_readiness.md` | release | `[]` | **DEFERRED.** Finalize the real reverse-DNS `applicationId` for **BOTH** apps; update Android/iOS build files; align `MapTileConfig.userAgentPackageName` (must match the chosen id) in the same commit; signing/build config; store metadata/data-safety. Canonical file — the driver domain references it, does not duplicate. Until it lands `userAgentPackageName` tracks the stock `com.example.rider_app`/`com.example.driver_app`. |
| `[location]_android_location_permission.md` | location | `[]` | **Android-only; LOCKED 2026-10-06.** Add `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` + `uses-feature android.hardware.location.gps required="true"` (accept that Play may hide the app from non-GPS devices) to the main manifest; **no** `ACCESS_BACKGROUND_LOCATION`; **no** minSdk change; manifests-only — the `deniedForever` settings deep-link is handed to the landed `[location]` fallback (see Landed `[location]`). Cross-domain: driver main manifest has the same gap plus a driver-specific background question. |

The two `[map]` deferred plans are **siblings, not a chain**: both are alternatives/composables over
the same shared `MapTileConfig`, gated behind the open `[map]_android_tile_access.md`. They stay
unnumbered with `depends_on: []` and carry `status: deferred` (numbering is reserved for sequential
stages; two same-tag branch heads cannot both be `01_`). Flip a plan's `status` to `open` and revisit
its `depends_on` when the active map plan lands.

Earlier wave plans — `[tracking]_ride_detail_receipt_rating.md` (LC-3 + LC-4) and
`01_[ontrip]_live_route_and_eta.md` — landed, were condensed into Landed above, and were deleted
(2026-10-03). The most recent open plan, `[multi]_rider_stop_list_ui.md`, landed, was condensed into
Landed `[multi]` above, and was deleted (2026-10-06). `[home]_bottom_panel_resize.md` and
`[rating]_unify_rating_ui.md` landed, were condensed into Landed `[home]`/`[rating]` above, and
were deleted (2026-10-08).

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
  `ACCESS_BACKGROUND_LOCATION`). Not designed in `[map]_android_tile_access.md`, which only notes the
  handoff.
- **The shell owns the only `Scaffold` on the six section routes.** Section screens are body-only.
  In particular the rider settings screen composes the shared `AppSettingsSection`/`AppSettingsRow`
  rows directly rather than reusing the shared `AppSettingsScreen`, because `AppSettingsScreen`
  hardcodes its own `Scaffold`/`AppBar` and nesting it would render two app bars. Any new shared
  full-screen widget intended for the shell must likewise be body-only (or expose a body-only
  variant).
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
