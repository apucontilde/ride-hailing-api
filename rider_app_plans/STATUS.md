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
- Ride detail + receipt + rating (LC-3) — `features/home/data/ride_provider.dart` `fetchRide:90`,
  `fetchReceipt:116`, `resolveFare:137`, `rateRide:156` (per-ride `RatingOutcome`, a 409
  `UNIQUE(ride_id, rater_role)` maps to `alreadyRated`, not failure); **ride-scoped** `canRate:73`
  (`!isRating && !ratedRideIds.contains(rideId)`; `ratingRideId` scopes the transient outcome so a
  rated ride no longer suppresses every later ride). `rating_prompt_dialog.dart:27-37` disables all
  five stars for the in-flight window (double-submit guard over an unhardened backend); completion
  flow `active_ride_screen.dart:205-219`, receipt dialog `:225-322`, rating prompt `:289-301`;
  tests `test/features/home/data/ride_provider_test.dart`.
- Already-rated seed walk — `riderRatedRideIdsProvider` reads **every** page of `GET /rider/ratings`
  (per_page 50), bounded by `ratedRideIdsMaxPages` = 20 (1000 ratings) —
  `features/home/data/ride_provider.dart:232-272`; wired `active_ride_screen.dart:80,142-145`.
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

### [web]
- Ride creation on web/CORS: backend allows `Idempotency-Key`
  (`internal/router/router.go:55`; asserted `internal/router/router_test.go:32`); shared
  cross-platform WS with query token (`shared/lib/src/network/websocket_service.dart:3,56-58`);
  dispatch pushes `no_driver_available` (`internal/service/dispatch.go:59-64,67-76,92`).

### [map]
- Zoom-to-fit pickup + dropoff — `features/home/presentation/home_screen.dart:32-40`
  (`_fitBounds` / `CameraFit.bounds`).
- Dropoff marker refresh — `home_screen.dart:139-140` (MarkerLayer gate includes `_destination`).
- Server route polyline — `features/home/data/home_provider.dart:77-135` (`NavigationRoute`,
  `navigationRouteProvider`); `home_screen.dart:82,110-138` watches and renders it.
- Route fallback honesty (`01_[map]_route_fallback_honesty.md`): `NavigationRoute.isEstimate`
  parsed (`home_provider.dart:81,94`); grey dashed `StrokePattern.dashed(segments: [12,8])`
  drawn for error/loading/estimate/<2 points (`home_screen.dart:149-195`); solid blue only
  for non-estimate `data`; `"Estimated "` prefixed in `_buildRouteInfo` (`home_screen.dart:451`);
  error surfaced via `apiErrorMessage` + Retry button (`home_screen.dart:412-445`); tests
  in `test/features/home/data/home_provider_test.dart` (`is_estimate` true/false) and
  `test/features/home/presentation/home_screen_test.dart`.

### [routing]
- Routing data in the API — landed/superseded by the `api_plans/` series (A* engine
  `internal/routing/`, the OSM import script / `make import-osm`, strict param validation
  `internal/handler/platform.go:516-527`). Structural note: the plan specified
  `internal/service/router/`; the engine lives in `internal/routing/`.

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
| 2 | `home_screen.dart` route `error: (_, _)` branch still fires on **every** error status and discards the exception; it now draws the honest grey dashed fallback (not a confident blue line) and the error text/Retry is surfaced, but narrowing the branch to 5xx-only is a logged follow-up | `features/home/presentation/home_screen.dart:179-195` (post-fix) | low | [map] |
| 3 | Forgot-password was a local `setState` fake; `ApiEndpoints.forgotPassword` dead — **FIXED**: `AuthNotifier.forgotPassword` POSTs the real endpoint and the screen drives success/error | `rider_app/lib/core/auth/auth_provider.dart:44-51`; `features/auth/presentation/forgot_password_screen.dart:38-64` | medium | [auth] |
| 4 | History screen hardcoded "No rides yet" — **FIXED**: paginated `historyProvider` + pull-to-refresh/infinite-scroll list with distinct empty/error states | `features/home/data/history_provider.dart:56-102`; `features/home/presentation/history_screen.dart:46,53-68` | medium | [history] |
| 5 | Security/SOS screen placeholder; `ApiEndpoints.sos` dead — **FIXED**: confirm-dialog SOS POST with the ack-only caption | `features/home/data/security_provider.dart:36-68`; `features/home/presentation/security_screen.dart:8-29,58-84` | medium | [safety] |
| 6 | `nearbyDriversProvider` declared but never consumed — **FIXED**: `family` provider consuming `{drivers:[...]}`, surfaced via `NearbyDriversChip` | `features/home/data/home_provider.dart:12-24`; `features/home/presentation/nearby_drivers_chip.dart:6-21` | low | [geo] |
| 7 | No code called `PUT /geo/rider/location` — **FIXED**: lease-counted `LocationPingService` (5 s throttle) started by Home + matching + active-trip | `features/home/data/location_ping_service.dart:42-81`; `features/home/presentation/home_screen.dart:32-50` | medium | [geo] |
| 8 | `current_ride_provider` poll only self-stopped on `no_driver_available`; cancel/complete relied on screen navigation — **FIXED**: self-stops on any terminal status | `features/home/data/current_ride_provider.dart:90-93,111-113` | low | [tracking] |
| 9 | Sidebar existed only on `/home`; `AppSidebar.selectedRoute` wired but unconsumed — **FIXED**: app-wide `RiderShell` `ShellRoute` consumes `selectedRoute`; flow routes stay drawer-free | `features/navigation/rider_shell.dart:26-92`; `core/router/app_router.dart:56-86` | low | [nav] |
| 10 | Place autocomplete fired one request per keystroke (no debounce) AND up to 4 sequential requests per query via the `_radiusSteps` 1000/3000/10000/30000 m loop — **FIXED** by `[search]_throttle_place_autocomplete.md`: 350 ms `placeSearchDebounceProvider` (`features/home/data/home_provider.dart:53-54`) with cancel-then-rearm `_debounceTimer` (`features/home/presentation/location_search_screen.dart:28,37-43`), and a single `_searchRadiusM = 30000.0` request (`features/home/data/home_provider.dart:51,56-74`) | pre-fix `features/home/presentation/location_search_screen.dart:50-52`; `features/home/data/home_provider.dart:51,58-73` | medium | [search] |
| 11 | `riderRatedRideIdsProvider` seed walk is a **documented bound**: `ratedRideIdsMaxPages` = 20 × 50 = 1000 rated rides. A rider past that ceiling could be re-prompted for an ancient completed ride — non-fatal, the prompt's 409 → `alreadyRated` guard swallows it | `features/home/data/ride_provider.dart:239,247-271` | low | [tracking] |

## Open plans

**None.** Both wave plans — `[tracking]_ride_detail_receipt_rating.md` (LC-3 + LC-4) and
`01_[ontrip]_live_route_and_eta.md` — landed and were condensed into Landed above and deleted
(2026-10-03). The rider domain has no open plans.

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
- The API never answers an outage with 4xx: the rider's route `error: (_, _)` branch still fires on
  every error status (`home_screen.dart:179-195`), so an outage must be 5xx or `is_estimate: true`.
- **The active trip never draws a confident road-less route.** `TripRouteState.unavailable` carries
  no polyline and the screen renders only the "Route unavailable" banner; `isEstimate` is grey +
  dashed behind an explicit banner; solid blue is reserved for `ready`
  (`active_ride_screen.dart:420-466`). An `etaSeconds` of `300` is "unknown", never a rendered ETA
  (`trip_eta.dart:5`).

### Skip list (backend still STUB — do NOT build UI) — authoritative

| Area | Endpoints | Why skip |
|---|---|---|
| Payment methods | `GET/POST/DELETE /rider/payment-methods` | all STUB (`StubPayment`) — keep `PaymentScreen` placeholder |
| Tipping | `POST /rides/:id/tip` | STUB |
| Promotions | `GET /promotions`, `POST /promotions/apply` | STUB (empty list / ack) |
| Place details/geocode | `GET /places/geocode`, `GET /places/details` | STUB (`{"place":null}`) |
| Analytics | `GET /geo/isochrone`, `GET /heatmap` | STUB/placeholder |
| Devices/push | `POST /devices`, `DELETE /devices/:token` | no push pipeline |
| Feedback | `POST /feedback` | ack only |
| Social/verify | `POST /auth/social`, `verify-email`, `verify-phone` | STUB/PARTIAL (code ignored) |
| Destination change | `PUT /rides/:id/destination` | STUB (ack, no mutation) |
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

Last wave (LC-3 + LC-4 + `[ontrip]`, 2026-10-03): rider 274 tests green, `melos run analyze` clean.
LC-3/LC-4 and `[ontrip]` landing claims adversarially reviewed before condensing.
