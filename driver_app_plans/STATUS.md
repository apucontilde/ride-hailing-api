# driver_app — Status

> Make `driver_app/` really drive every driver-facing capability the API offers. Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see Verification).

## Landed

### [ws]
- Typed `DriverWebSocketService` facade + `WsEventType` (`offer`/`updated`/`location`/`other`) — `driver_app/lib/core/network/websocket_service.dart:20`, `driver_app/lib/core/network/ws_event.dart:6`; tests `driver_app/test/core/network/websocket_service_test.dart`.
- `RideStateNotifier` owns the ride state machine: offer + 30 s expiry, single-offer policy, current ride, `ride.updated` patch merge via `RideUpdate.applyTo` — `driver_app/lib/core/ride/ride_state_notifier.dart:44,116-117,94`, `driver_app/lib/core/ride/ride_update.dart:76`; tests `driver_app/test/core/ride/ride_state_notifier_test.dart`.
- Terminal ride replacement + `lastLocation` cleanup: `Ride.isTerminal` (`shared/lib/src/models/ride.dart:88`); `_onRideUpdated` terminal-aware guard (`ride_state_notifier.dart:89-101`); `lastLocation`/`clearLocation` removed (`ride_state_notifier.dart:15-41`, `clearRide`); location event no-op (`ws_event.dart:75`); tests `ride_state_notifier_test.dart`.

### [online]
- Availability toggle `PUT /driver/me/status` (double-tap guarded, reverts on failure) — `driver_app/lib/features/home/providers/availability_notifier.dart:33`; tests `driver_app/test/features/home/providers/availability_notifier_test.dart`.
- Location stream: ≥5 s throttle, online-only push, 60-point batch flush on recovery, `publishLastPosition()` when going online, `lastPositionProvider` — `driver_app/lib/core/location/location_service.dart:59,106,55`; tests `driver_app/test/core/location/location_service_test.dart`.
- Permission state: `LocationHelper.requestPermissionDetailed()` (record result) → `LocationService.onPermission` → `appPermissionProvider` (granted/deniedPermanently); `requestPermission()` keeps existing bool contract (`shared/lib/src/utils/location_helper.dart:4-22`, `location_service.dart:112-116`); `home_screen.dart:49-55` always starts stream and only requests when not resolved; `app.dart:18-23` collapsed to single authenticated branch (`app.dart:16-21`); banner renders on permanent denial (`home_screen.dart:200-218`); service permission test (`location_service_test.dart`) + banner widget test (`home_screen_test.dart`).

### [offer]
- Offer sheet + accept (WS-first, HTTP fallback, 409 → `OfferExpiredException`) / decline (WS-only) — `driver_app/lib/features/rides/presentation/offer_sheet.dart:96-121`, `driver_app/lib/features/rides/data/rides_repository.dart:48,54-55`; tests `driver_app/test/features/rides/presentation/offer_sheet_test.dart`, `driver_app/test/features/rides/data/rides_repository_test.dart`.

### [trip]
- Journey state machine + single-button trip screen + `GET /driver/rides/current` launch restore — `driver_app/lib/features/trip/providers/trip_notifier.dart:101`, `driver_app/lib/features/trip/presentation/trip_screen.dart`, `driver_app/lib/features/rides/data/rides_repository.dart:64`, `driver_app/lib/features/home/presentation/home_screen.dart:60-64`; tests `driver_app/test/features/trip/providers/trip_notifier_test.dart`, `driver_app/test/features/trip/presentation/trip_screen_test.dart`, `driver_app/test/features/home/presentation/home_screen_test.dart`.
- Route error surfacing: `routeError` carried on `TripState` (`trip_notifier.dart:64,92-94,268,272`), rendered via `_StageControls` (`trip_screen.dart:512-534`); provider + widget tests covered. Landed `<commit>` (plan `01_[trip]_route_error_surfacing.md`); depends on `api_plans/[errors]_route_outage_contract_test.md` (landed).

### [history]
- History + client-side earnings + rate rider — `driver_app/lib/features/rides/providers/history_provider.dart:64,275`, `driver_app/lib/features/rides/presentation/rides_history_screen.dart`, `driver_app/lib/features/rides/presentation/rate_sheet.dart:14`; tests `driver_app/test/features/rides/providers/history_provider_test.dart`, `driver_app/test/features/rides/presentation/rides_history_screen_test.dart`, `driver_app/test/features/rides/presentation/rate_sheet_test.dart`.
- Contract notes: rate body field is `score` (not `rating`); history pagination is 1-based `page`/`per_page` (not `limit`/`offset`).

### [profile]
- Profile / vehicle / settings screens + `ProfileNotifier.updateProfile` (partial fields, cache replace, error preserve) — `driver_app/lib/features/profile/presentation/profile_screen.dart`, `driver_app/lib/features/vehicle/presentation/vehicle_screen.dart`, `driver_app/lib/features/settings/presentation/settings_screen.dart`, `driver_app/lib/features/profile/providers/profile_notifier.dart:56`. ⚠️ Shipped with no tests — see open plan + bugs.

### [nav]
- Shared core + both adoptions (the shared-symbol inventory lives in `rider_app_plans/STATUS.md` under [nav]).
  Driver adoption here: drawer → `AppSidebar` `driver_app/lib/features/home/presentation/home_screen.dart:166`;
  shared hamburger in the AppBar `.../home_screen.dart:129`; app-owned list
  `driver_app/lib/features/navigation/driver_nav_items.dart:23` (`includeVehicle` gate = `lib/config.dart:12`);
  settings → `AppSettingsScreen` `.../settings_screen.dart:24`; profile →
  `AppProfileHeader`/`AppProfileForm`/`AppNavLinkCard`
  `driver_app/lib/features/profile/presentation/profile_screen.dart:59,77,96`. New suites
  `driver_app/test/features/{navigation,profile,settings}/` — the profile + settings halves of bug #4
  are now tested and the header's initials/fallback/chip logic gets its first assertions;
  `test/features/vehicle/` stays with `[profile]` (the flag is false, the screen unreachable).

## Known bugs & issues

Source citations in this file are **fully qualified from the repo root** (`rider_app/lib/...`,
`driver_app/lib/...`) or from the owning app root where the row's own column makes it
unambiguous; Go and cross-package paths are repo-relative. Never cite a bare
`home_screen.dart` — both apps have one.

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 1 | (Fixed by `[online]_permission_state.md`) `appPermissionProvider` is now written via `LocationService.onPermission` (`location_service.dart:68,224`) mapping `LocationHelper.requestPermissionDetailed()` result (`shared/lib/src/utils/location_helper.dart:4-22`); denial banner renders (`home_screen.dart:200-218`). | `driver_app/lib/core/location/location_service.dart:68,224`; `shared/lib/src/utils/location_helper.dart:4-22` | resolved | [online] |
| 6 | (Fixed by `[online]_permission_state.md`) `app.dart` collapsed to single `service.start()` branch (`app.dart:16-21`). | `driver_app/lib/app.dart:16-21` | resolved | [online] |
| 2 | Onboarding collects first/last name but never `PUT /driver/me` | `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:44` | medium | [profile] |
| 3 | The profile + settings screens now have suites (`driver_app/test/features/{profile,settings}/`); the vehicle screen still has none — its flag is false so it is unreachable — and `test/features/vehicle/` belongs to `[profile]_profile_settings_tests.md` | `driver_app/test/features/` | medium | [profile] |
| 4 | "Already rated" set is session-local (`GET /driver/ratings` is a stub) — **kept open**: backend-blocked, do not build UI on the stub. Server side now planned: `api_plans/[ratings]_ratings_list.md` | `driver_app/lib/features/rides/presentation/rate_sheet.dart:14` | low | [history] |
| 5 | No withdraw UI (`POST /driver/earnings/withdraw` is a stub) — **kept open**: backend-blocked, no app work until the API implements it. Server design settled but **deferred**: `api_plans/[payout]_driver_earnings_and_withdraw.md` | `driver_app/lib/features/rides/presentation/rides_history_screen.dart:11-13` | low | [history] |
| 6 | `/vehicle` is reachable only by deep link: both the drawer and the profile card omit it while `vehicleFeatureEnabled` is false (`lib/config.dart:12`), and the card row was the app's only `context.push('/vehicle')` — flipping the flag re-adds the row with no other change. **Kept open** as an intentional gate | `driver_app/lib/features/navigation/driver_nav_items.dart:23` | low | [profile] |
| 7 | Drawer exists only on `/home`, so switching sections costs a back-press — planned: `[nav]_app_wide_drawer.md` (ShellRoute around the top-level sections; `/trip` stays drawer-free) | `driver_app/lib/features/home/presentation/home_screen.dart:166` | low | [nav] |
| 8 | No driver-side keep-alive: `ping()` exists but is never called from production code (only `websocket_service_test.dart:74`), and `isConnected` is `_channel != null` (not liveness), so an idle socket dies on NAT/intermediary timeouts and dispatch's `isConnected` gate (`internal/service/dispatch.go:101-105`) skips a DB-fresh driver | `shared/lib/src/network/websocket_service.dart:39,136`; `driver_app/lib/core/network/websocket_service.dart:40` | medium | [dispatch] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[profile]_profile_settings_tests.md` | profile | none (independent) | the remaining vehicle suite (`test/features/vehicle/`) + onboarding name persistence via `PUT /driver/me` (the profile/settings suites already exist — landed by the `[nav]` chain) |
| `[safety]_sos_feedback.md` | safety | none (independent) | `safety_screen.dart` + `safety_repository.dart` + settings entry tile (now an `AppSettingsScreen.extraSections` group — the shared screen it lands in has landed) + tests; authoritative skip list |
| `01_[session]_switch_and_cancel_session.md` | session | `rider_app_plans/[session]_switch_account.md` (open, cross-domain) | driver login-screen adoption of the shared guarded switch-account flow (+ `login_screen_test.dart`); shared controller + backend semantics owned by the rider head |
| `01_[dispatch]_keepalive_and_offer_reliability.md` | dispatch | `api_plans/[dispatch]_reliability_and_no_driver_false_negative.md` (open, cross-domain) | driver heartbeat `ping()` on interval + re-publish-on-reconnect; server selection/liveness owned by the api head |
| `[nav]_app_wide_drawer.md` | nav | none (independent) | bug #8: `ShellRoute` around the top-level sections so the sidebar is app-wide (not just `/home`); `/trip` stays drawer-free |

## Invariants
- Tests use `mocktail` + `http_mock_adapter`, mirroring `driver_app/test/core/...`; never build UI on a backend STUB — the authoritative skip list is in `[safety]_sos_feedback.md`.
- Don't remove public providers used by other screens; extend them. `core/auth/auth_provider.dart` is the single owner of session/token state.
- New shared symbols are imported from the barrel directly — do **not** add shims. `shared/` owns no route table and no `go_router` dependency.
- The ride-state machine owns the primary button; widgets never hold paging state.
- The `/mnt/i/flutter` SDK has CRLF endings and is unusable; the working toolchain is the Linux FVM SDK at ~/fvm/default plus native Melos 8 at ~/.pub-cache/bin/melos (`export PATH=~/fvm/default/bin:$PATH` then `melos run analyze`/`melos run test`). The `make flutter-*` targets shell out to the Windows `melos.bat` and are broken from this WSL tree.

## Verification
```bash
export PATH=~/fvm/default/bin:$PATH   # Linux FVM SDK (the /mnt/i/flutter SDK has CRLF endings)
melos run analyze
melos run test
```
