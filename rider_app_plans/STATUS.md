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
  rated ride no longer suppresses every later ride). `rating_prompt_dialog.dart:27-37` disables all
  five stars for the in-flight window (double-submit guard over an unhardened backend); completion
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
- Fare honesty for stops (API gap, client-honest) — `home_screen.dart:474-499`
  (`stops-fare-note`): the estimate stays the single-leg API number and the limitation is named;
  no client stop surcharge. Tests `test/features/home/presentation/stop_list_test.dart`,
  `test/features/home/data/multi_leg_route_provider_test.dart:66-140`,
  `test/features/home/presentation/home_screen_test.dart:343+`.

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

### [routing]
- Routing data in the API — landed/superseded by the `api_plans/` series (A* engine
  `internal/routing/`, the OSM import script / `make import-osm`, strict param validation
  `internal/handler/platform.go:516-527`). Structural note: the plan specified
  `internal/service/router/`; the engine lives in `internal/routing/`.

### [fare]
- Pre-booking estimate shows the API **total** + a receipt-style breakdown — `RideEstimate` maps
  `total` and the additive legs (`distance_fare`/`time_fare`/`demand_multiplier`/
  `supply_multiplier`/`grade_uplift_pct`/`currency`) and no longer parses the dead `price` field
  `features/home/model/ride_estimate.dart:37,32-40,47,49,60`; the selected option renders
  `formattedTotal` plus base/distance/time/conditions/total lines, with a `climb +x%` note on the
  distance leg only when the uplift is non-zero and **no fuel line** —
  `features/home/presentation/ride_estimate_sheet.dart:110,126-152` (climb `:134-136`); currency
  comes from the API and an absent code renders the bare amount (`ride_estimate.dart:60`); tests
  `test/features/home/model/ride_estimate_test.dart`,
  `test/features/home/presentation/ride_estimate_sheet_test.dart`,
  `test/features/home/data/home_provider_test.dart:304-366`.

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
| 12 | Pre-booking estimate sheet showed the fixed `base_fare` instead of the computed `total`, and `RideEstimate` parsed a dead `price` JSON field the API never sends (always 0, unused) — **FIXED** by `[fare]_estimate_total_and_breakdown.md`: maps `total` + breakdown legs, removes `price`, renders the total with a receipt-style breakdown and API currency | post-fix `features/home/model/ride_estimate.dart:37,49,60`; `features/home/presentation/ride_estimate_sheet.dart:110,126-152`; pre-fix sheet `:108`, model `:26,58`; API sends `total`/`grade_uplift_pct` `internal/handler/responses.go:185,194` | medium | [fare] |
| 13 | **API gap (not rider work):** there is no waypoint-aware fare. `POST /rides` computes the quote from `pickup → dropoff` only and ignores the `stops[]` itinerary (`internal/service/ride.go:234`), and `GET /estimates/price` takes no stops — so a multi-stop trip is priced short. The rider UI is deliberately honest (single-leg API estimate + the `stops-fare-note` caveat) rather than inventing a client surcharge; fixing it is a future `api_plans [fare]` item | `internal/service/ride.go:234`; `features/home/presentation/home_screen.dart:474-499` | low | api_plans `[fare]` |

## Open plans

**None.** `rider_app_plans/` has no open plan files (checked 2026-10-06). The last open plan,
`[multi]_rider_stop_list_ui.md`, landed and was condensed into Landed `[multi]` above and deleted.

Earlier wave plans — `[tracking]_ride_detail_receipt_rating.md` (LC-3 + LC-4) and
`01_[ontrip]_live_route_and_eta.md` — landed, were condensed into Landed above, and were deleted
(2026-10-03).

## Invariants

- Keep the re-export-shim structure intact: never move app files into `shared/`, only ADD code there.
  New shared symbols are imported from the barrel directly — do **not** add shims for them.
- `shared/` holds no route table and no `go_router` dependency: route strings and navigation
  callbacks are owned by the app (see the `[nav]` Landed entry above).
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
