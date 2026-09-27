# driver_app — Status

> Make `driver_app/` really drive every driver-facing capability the API offers. Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see Verification).

## Landed

### [ws]
- Typed `DriverWebSocketService` facade + `WsEventType` (`offer`/`updated`/`location`/`other`) — `driver_app/lib/core/network/websocket_service.dart:20`, `driver_app/lib/core/network/ws_event.dart:6`; tests `driver_app/test/core/network/websocket_service_test.dart`.
- `RideStateNotifier` owns the ride state machine: offer + 30 s expiry, single-offer policy, current ride, `ride.updated` patch merge via `RideUpdate.applyTo` — `driver_app/lib/core/ride/ride_state_notifier.dart:44,116-117,94`, `driver_app/lib/core/ride/ride_update.dart:76`; tests `driver_app/test/core/ride/ride_state_notifier_test.dart`.

### [online]
- Availability toggle `PUT /driver/me/status` (double-tap guarded, reverts on failure) — `driver_app/lib/features/home/providers/availability_notifier.dart:33`; tests `driver_app/test/features/home/providers/availability_notifier_test.dart`.
- Location stream: ≥5 s throttle, online-only push, 60-point batch flush on recovery, `publishLastPosition()` when going online, `lastPositionProvider` — `driver_app/lib/core/location/location_service.dart:59,106,55`; tests `driver_app/test/core/location/location_service_test.dart`.

### [offer]
- Offer sheet + accept (WS-first, HTTP fallback, 409 → `OfferExpiredException`) / decline (WS-only) — `driver_app/lib/features/rides/presentation/offer_sheet.dart:96-121`, `driver_app/lib/features/rides/data/rides_repository.dart:48,54-55`; tests `driver_app/test/features/rides/presentation/offer_sheet_test.dart`, `driver_app/test/features/rides/data/rides_repository_test.dart`.

### [trip]
- Journey state machine + single-button trip screen + `GET /driver/rides/current` launch restore — `driver_app/lib/features/trip/providers/trip_notifier.dart:101`, `driver_app/lib/features/trip/presentation/trip_screen.dart`, `driver_app/lib/features/rides/data/rides_repository.dart:64`, `driver_app/lib/features/home/presentation/home_screen.dart:60-64`; tests `driver_app/test/features/trip/providers/trip_notifier_test.dart`, `driver_app/test/features/trip/presentation/trip_screen_test.dart`, `driver_app/test/features/home/presentation/home_screen_test.dart`.

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
| 1 | `appPermissionProvider` is read but never written (`requestPermission()` omits it), so the "denied" banner can never fire | `driver_app/lib/core/location/location_service.dart:30,106`; `driver_app/lib/features/home/presentation/home_screen.dart:47,82` | medium | [online] |
| 2 | `lastLocation` is stored but has no consumer (server pushes `driver.location` only to the rider) | `driver_app/lib/core/ride/ride_state_notifier.dart:17,76` | low | [ws] |
| 3 | Onboarding collects first/last name but never `PUT /driver/me` | `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:44` | medium | [profile] |
| 4 | The profile + settings screens now have suites (`driver_app/test/features/{profile,settings}/`); the vehicle screen still has none — its flag is false so it is unreachable — and `test/features/vehicle/` belongs to `[profile]_profile_settings_tests.md` | `driver_app/test/features/` | medium | [profile] |
| 5 | "Already rated" set is session-local (`GET /driver/ratings` is a stub) | `driver_app/lib/features/rides/presentation/rate_sheet.dart:14` | low | [history] |
| 6 | No withdraw UI (`POST /driver/earnings/withdraw` is a stub) | `driver_app/lib/features/rides/presentation/rides_history_screen.dart:11-13` | low | [history] |
| 7 | Redundant authenticated branches in `app.dart` (both only call `service.start()`) | `driver_app/lib/app.dart:18-23` | low | [online] |
| 8 | Prior README test total was stale at HEAD (171 vs 179 actual) — re-count, do not reuse old numbers | `grep -rhE "^\s*(test\|testWidgets)\(" driver_app/test` = 224 | low | — |
| 9 | `/vehicle` is reachable only by deep link: both the drawer and the profile card omit it while `vehicleFeatureEnabled` is false (`lib/config.dart:12`), and the card row was the app's only `context.push('/vehicle')` — flipping the flag re-adds the row with no other change | `driver_app/lib/features/navigation/driver_nav_items.dart:23` | low | [profile] |
| 10 | Drawer exists only on `/home`, so switching sections costs a back-press; making it app-wide needs a `ShellRoute` or a `drawer:` on every `Scaffold` plus a back-button-vs-hamburger decision | `driver_app/lib/features/home/presentation/home_screen.dart:166` | low | [nav] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[profile]_profile_settings_tests.md` | profile | none (independent) | the remaining vehicle suite (`test/features/vehicle/`) + onboarding name persistence via `PUT /driver/me` (the profile/settings suites already exist — landed by the `[nav]` chain) |
| `[safety]_sos_feedback.md` | safety | none (independent) | `safety_screen.dart` + `safety_repository.dart` + settings entry tile (now an `AppSettingsScreen.extraSections` group — the shared screen it lands in has landed) + tests; authoritative skip list |

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
