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

### [routing]
- Routing data in the API — landed/superseded by the `api_plans/` series (A* engine
  `internal/routing/`, the OSM import script / `make import-osm`, strict param validation
  `internal/handler/platform.go:516-527`). Structural note: the plan specified
  `internal/service/router/`; the engine lives in `internal/routing/`.

### [auth]
- Real rider profile / account — `rider_app/lib/core/auth/auth_provider.dart:20,38-99`
  (`riderProfileProvider`, `refreshProfile`, `onLoggedOut` cache clearing);
  `features/profile/providers/profile_notifier.dart`; `features/home/presentation/profile_screen.dart`;
  drawer header `features/home/presentation/home_screen.dart:96`; shared `AuthUser` fields
  `shared/lib/src/models/auth_user.dart:12-14,62` and the logout hook
  `shared/lib/src/auth/app_auth_controller.dart:84,231`. Tests present.

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
- Rider adoption: drawer → `AppSidebar` `features/home/presentation/home_screen.dart:96`; app-owned list
  `features/navigation/rider_nav_items.dart:20`; shared toggle (double inset removed)
  `features/home/presentation/home_screen.dart:215`; settings → `AppSettingsScreen`
  `features/settings/presentation/settings_screen.dart:25`; profile →
  `AppProfileHeader`/`AppProfileForm`/`AppNavLinkCard`
  `features/home/presentation/profile_screen.dart:81,99,110`. Tests `test/features/navigation/`.

## Known bugs & issues

Source citations in this file are **relative to the app root** (`features/.../screen.dart:N`)
unless they cross a package, in which case they are repo-relative
(`rider_app/lib/...`, `shared/lib/...`, `internal/...`). Never cite a bare
`home_screen.dart` — both `rider_app` and `driver_app` have one.

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 1 | `ActiveRideScreen` reads invented `driver_lat`/`driver_lng` and `driver_name`/`car_model` instead of typed `RideState.driver`/`driverLocation` | `features/home/presentation/active_ride_screen.dart:109,173-174` | high | [tracking] |
| 2 | `home_screen.dart` `error: (_, _) => Polyline(...)` draws a straight line on EVERY error status, discarding the exception; narrowing to 5xx-only is a logged follow-up | `features/home/presentation/home_screen.dart:128` | high | [map] |
| 3 | Forgot-password screen is a local `setState` fake; `ApiEndpoints.forgotPassword` dead | `features/auth/presentation/forgot_password_screen.dart:26-29`; `core/api/endpoints.dart:5` | medium | [auth] |
| 4 | History screen hardcodes "No rides yet" | `features/home/presentation/history_screen.dart:13` | medium | [history] |
| 5 | Security/SOS screen is a placeholder; `ApiEndpoints.sos` dead | `features/home/presentation/security_screen.dart:13`; `core/api/endpoints.dart:27` | medium | [safety] |
| 6 | `nearbyDriversProvider` declared but never consumed | `features/home/data/home_provider.dart:12` (sole reference) | low | [geo] |
| 7 | No code calls `PUT /geo/rider/location` — rider location never streamed | `features/home/presentation/active_ride_screen.dart:29-42` (only local-position listener, no API call) | medium | [geo] |
| 8 | `current_ride_provider` poll only self-stops on `no_driver_available`; cancel/complete stop relies on screen navigation | `features/home/data/current_ride_provider.dart:102` | low | [tracking] |
| 9 | Sidebar exists only on `/home`, so switching sections costs a back-press; `AppSidebar.selectedRoute` is wired but no section-level sidebar consumes it (needs a `ShellRoute`/app-wide `drawer:` + a back-hamburger decision) | `features/home/presentation/home_screen.dart:96` | low | [nav] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[tracking]_ride_detail_receipt_rating.md` | tracking | — | ride detail + receipt + rating UI (LC-3) and typed live driver tracking (LC-4) |
| `[history]_ride_history.md` | history | — | real paginated ride-history list |
| `[geo]_rider_location_ping.md` | geo | — | rider-location ping (GEO-1) + `nearbyDriversProvider` consumer chip (GEO-3) |
| `[auth]_forgot_password.md` | auth | — | real forgot-password (AC-1) |
| `[safety]_sos.md` | safety | — | SOS button + authoritative backend skip list |

## Invariants

- Keep the re-export-shim structure intact: never move app files into `shared/`, only ADD code there.
  New shared symbols are imported from the barrel directly — do **not** add shims for them.
- `shared/` holds no route table and no `go_router` dependency: route strings and navigation
  callbacks are owned by the app (see the `[nav]` Landed entry above).
- Tests use `mocktail` + `http_mock_adapter`, mirroring the existing suites.
- Never build UI around a backend STUB (see the skip list in `[safety]_sos.md`).
- Don't remove public providers used by other screens; extend them.
- The API never answers an outage with 4xx: the rider's straight-line fallback fires on every
  error status (`home_screen.dart:128`), so an outage must be 5xx or `is_estimate: true`.

## Verification

```bash
export PATH=~/fvm/default/bin:$PATH   # Linux FVM SDK (the /mnt/i/flutter SDK has CRLF endings)
melos run analyze
melos run test
```

(`make flutter-analyze`/`make flutter-test` are broken from this WSL tree — they shell out to the
Windows `melos.bat` through `cmd.exe`, which cannot `cd` into the UNC path. Native Melos 8 is at
`~/.pub-cache/bin/melos`.)
