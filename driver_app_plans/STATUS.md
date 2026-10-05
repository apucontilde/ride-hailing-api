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

### [dispatch]
- Keep-alive + re-publish-on-reconnect (driver half of the dispatch false-negative fix). Shared service owns an **opt-in** heartbeat: `heartbeatInterval` (default `Duration.zero`), idempotent `startHeartbeat`/`stopHeartbeat`, armed by `connect()` (`startHeartbeat()` + `onConnected`), stopped by `_handleDisconnect`/`disconnect`/`dispose` — `shared/lib/src/network/websocket_service.dart:37,57,112-113,148,159,124,177,204`. Driver facade opts into 25 s, re-arms per `setOnline` and on reconnect with an immediate `ping` — `driver_app/lib/core/network/websocket_service.dart:17,43,45-55,78-86`.
- Wiring: `availability.onOnlineChanged = websocket.setOnline` (online pings, offline stops) and `websocket.onReconnected = () => service.publishLastPosition()` (a freshly reconnected driver is immediately dispatchable) — `driver_app/lib/core/location/location_service.dart:245,249`; callback invoked on every transition at `driver_app/lib/features/home/providers/availability_notifier.dart:41,57,64,71,101,111`. **Design deviation:** heartbeat is opt-in per app (shared default zero) and driver-only at 25 s so the rider app keeps no pending timer in widget tests; `isConnected` deliberately stays "open, not alive" (`shared/lib/src/network/websocket_service.dart:62-70`). Tests: `shared/test/network/websocket_service_test.dart` (6), `driver_app/test/core/network/websocket_service_test.dart` (8; non-stacking upper bounds + post-reconnect ping), `driver_app/test/core/location/location_service_test.dart` (12; incl. end-to-end `onReconnected → publishLastPosition` at :419), `driver_app/test/features/home/providers/availability_notifier_test.dart` (10; `onOnlineChanged` at :118).

### [offer]
- Offer sheet + accept (WS-first, HTTP fallback, 409 → `OfferExpiredException`) / decline (WS-only) — `driver_app/lib/features/rides/presentation/offer_sheet.dart:96-121`, `driver_app/lib/features/rides/data/rides_repository.dart:48,54-55`; tests `driver_app/test/features/rides/presentation/offer_sheet_test.dart`, `driver_app/test/features/rides/data/rides_repository_test.dart`.

### [trip]
- Journey state machine + single-button trip screen + `GET /driver/rides/current` launch restore — `driver_app/lib/features/trip/providers/trip_notifier.dart:101`, `driver_app/lib/features/trip/presentation/trip_screen.dart`, `driver_app/lib/features/rides/data/rides_repository.dart:64`, `driver_app/lib/features/home/presentation/home_screen.dart:60-64`; tests `driver_app/test/features/trip/providers/trip_notifier_test.dart`, `driver_app/test/features/trip/presentation/trip_screen_test.dart`, `driver_app/test/features/home/presentation/home_screen_test.dart`.
- Route error surfacing: `routeError` carried on `TripState` (`trip_notifier.dart:64,92-94,268,272`), rendered via `_StageControls` (`trip_screen.dart:512-534`); provider + widget tests covered. Landed (plan `01_[trip]_route_error_surfacing.md`); depends on `api_plans/[errors]_route_outage_contract_test.md` (landed).

### [history]
- History + client-side earnings + rate rider + server-backed "already rated" set — `driver_app/lib/features/rides/providers/history_provider.dart:64,275`, `driver_app/lib/features/rides/presentation/rides_history_screen.dart`, `driver_app/lib/features/rides/presentation/rate_sheet.dart:14`, `driver_app/lib/features/rides/data/rated_rides_provider.dart:81,137`; tests `driver_app/test/features/rides/providers/history_provider_test.dart`, `driver_app/test/features/rides/presentation/rides_history_screen_test.dart`, `driver_app/test/features/rides/presentation/rate_sheet_test.dart`, `driver_app/test/features/rides/data/rated_rides_provider_test.dart`.
- Contract notes: rate body field is `score` (not `rating`); history pagination is 1-based `page`/`per_page` (not `limit`/`offset`).
- Server-backed rated rides (closes bug #4): `GET /driver/ratings` is real (rater-scoped, newest-first, paginated) and the app now consumes it — route `internal/router/router.go:203`, handler `internal/handler/ride.go:427-473`, repo `internal/repository/ride_repo.go:351-370`, migration `015_ratings_rater_index.up.sql`; app `driver_app/lib/features/rides/data/rated_rides_provider.dart:81,137` + `rides_repository.dart:180`.
- Laziness is expected, not a bug: `ratedRidesProvider` is a non-autoDispose `AsyncNotifierProvider`, so it fetches only when a watching screen mounts — History (`rides_history_screen.dart:56`) or Trip (`trip_screen.dart:178`). A cold launch parked on `/home` does not call `GET /driver/ratings` until one of those mounts; uncalled lookups stay `unknown`, never a false `unrated`.

### [profile]
- Profile / vehicle / settings screens + `ProfileNotifier.updateProfile` (partial fields, cache replace, error preserve) — `driver_app/lib/features/profile/presentation/profile_screen.dart`, `driver_app/lib/features/vehicle/presentation/vehicle_screen.dart`, `driver_app/lib/features/settings/presentation/settings_screen.dart`, `driver_app/lib/features/profile/providers/profile_notifier.dart:56`.
- Onboarding now persists the collected identity: after `POST /driver/register` succeeds it calls `ProfileNotifier.updateProfile(firstName:, lastName:)` (a sparse `PUT /driver/me`) **non-fatally** before routing to `/home`, so a failed save still lands the driver and leaves the edit form as the retry path — `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:42-48`; tests `driver_app/test/features/onboarding/presentation/onboarding_screen_test.dart` (2: body is exactly `{first_name,last_name}`; failed save still reaches `/home`). Closes bug #2.
- Tests: `driver_app/test/features/profile/providers/profile_notifier_test.dart` (5: sparse body, trim/drop blanks, cache replace, failure preserves old profile + error, malformed response), `driver_app/test/features/profile/presentation/profile_screen_test.dart` (13: header initials/fallback/chip/rating, sparse save, phone validation, error key, saving state, nav card), `driver_app/test/features/settings/presentation/settings_screen_test.dart` (5: app info/server/sign-out, safety row → `/safety`, confirm copy, cancel keeps session, confirm clears + `/login`).
- ⚠️ **Deviation from the plan:** its third suite (`test/features/vehicle/` + a "gated vehicle tile shows coming soon" assertion) was **not added** — `vehicleFeatureEnabled` is `false` (`driver_app/lib/config.dart:12`), the vehicle screen is unreachable, and the profile suite instead asserts the vehicle row is **absent** (`profile_screen_test.dart:336-346`). Dispositioned as bugs #3 (no vehicle suite) and #6 (deep-link-only gate); not claimed as full coverage.

### [safety]
- Ack-only safety/support surface (US-12): `SafetyRepository` fires `POST /api/v1/sos` with `{lat,lng}` and `POST /api/v1/feedback` with `{type:'app_issue', message}` and lets `DioException` escape so the screen can distinguish success from failure — `driver_app/lib/features/safety/data/safety_repository.dart:19,26`, endpoints `driver_app/lib/core/api/endpoints.dart:46-47`.
- `SafetyScreen`: SOS sends `lastPositionProvider` (guards on a missing fix rather than sending `null` coords) and feedback opens a dialog; both surface an ack/error SnackBar and state plainly that SOS does **not** contact emergency services (backend is ack-only) — `driver_app/lib/features/safety/presentation/safety_screen.dart:16,35`; entry row via the shared `AppSettingsSection`/`AppSettingsRow` — `driver_app/lib/features/settings/presentation/settings_screen.dart:71-80`; `/safety` route (outside the shell, keeps its back arrow) — `driver_app/lib/core/router/app_router.dart:106-109`.
- Tests: `driver_app/test/features/safety/data/safety_repository_test.dart` (2: real repository through a Dio mock adapter pins URL + body for both calls), `driver_app/test/features/safety/presentation/safety_screen_test.dart` (6: SOS body/ack, no-fix guard, SOS failure, feedback `app_issue` + close, empty message no-op, feedback failure).

### [session]
- Driver login adopts the shared **guarded switch-account** flow: before delegating, `_submit()` asks `AuthNotifier.needsAccountSwitch(email)` and, when already authenticated as someone else, shows the shared "Sign out of <current> and sign in as <new>?" confirmation and calls `switchAccount()` (which revokes the prior refresh token first) instead of clobbering the session — `driver_app/lib/features/auth/presentation/login_screen.dart:52-75`; shared controller `shared/lib/src/auth/app_auth_controller.dart:135,171`. Tests `driver_app/test/features/auth/presentation/login_screen_test.dart` (8; switch/cancel at :214, confirm revokes-then-logs-in at :245).

### [nav]
- App-wide driver drawer via `ShellRoute` (closes bug #7): `DriverShell` owns the single `Scaffold`/`AppBar`/`AppSidebar` for the five top-level sections, with `selectedRoute` highlighting the active section, account header, and sign-out footer; section screens are body-only so the toggle's `Scaffold.of(context)` always resolves to the shell's drawer — `driver_app/lib/features/navigation/driver_shell.dart:26,59-71`; `ShellRoute` registration `driver_app/lib/core/router/app_router.dart:77-102`; `/trip` and `/safety` deliberately stay outside (`app_router.dart:106-110`). Tests `driver_app/test/features/navigation/driver_shell_test.dart` (7; real-`routerProvider` structural at :173, `selectedRoute` highlight at :158).
- Home's rich header moved into the body (`driver_app/lib/features/home/presentation/home_screen.dart:118-158`); profile and settings are body-only (`profile_screen.dart:53-58`, `settings_screen.dart:25-30`).
- Settings composes the shared rows directly and does **not** use the shared `AppSettingsScreen`, which hardcodes its own `Scaffold`/`AppBar` and therefore cannot nest in the shell — `driver_app/lib/features/settings/presentation/settings_screen.dart:8-19,30`.
- Shared core + nav-item parity (the shared-symbol inventory lives in `rider_app_plans/STATUS.md` under [nav]). Driver-owned list `driver_app/lib/features/navigation/driver_nav_items.dart:23` (`includeVehicle` gate = `driver_app/lib/config.dart:12`); new suites `driver_app/test/features/{navigation,profile,settings}/` — the profile + settings halves of the old untested-surface bug now have assertions; `test/features/vehicle/` stays absent (bugs #3/#6).

## Known bugs & issues

Source citations in this file are **fully qualified from the repo root** (`rider_app/lib/...`,
`driver_app/lib/...`) or from the owning app root where the row's own column makes it
unambiguous; Go and cross-package paths are repo-relative. Never cite a bare
`home_screen.dart` — both apps have one.

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 1 | (Fixed by `[online]_permission_state.md`; consolidates the old permission + single-auth-branch rows) `appPermissionProvider` is now written via `LocationService.onPermission` mapping `LocationHelper.requestPermissionDetailed()`, so the denial banner fires, and `app.dart` collapsed to a single `service.start()` branch. | `driver_app/lib/core/location/location_service.dart:68,231`; `shared/lib/src/utils/location_helper.dart:4-22`; `driver_app/lib/app.dart:16-21`; `driver_app/lib/features/home/presentation/home_screen.dart:200-218` | resolved | [online] |
| 2 | (Fixed by `[profile]_profile_settings_tests.md`) Onboarding now `PUT /driver/me` with the collected first/last name after registration, non-fatally, before routing to `/home`. | `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:45-48`; `driver_app/test/features/onboarding/presentation/onboarding_screen_test.dart:133,156` | resolved | [profile] |
| 3 | The profile + settings screens have suites; the **vehicle screen still has none** — the `[profile]` plan's third suite was not added and its flag is false so the screen is unreachable. The profile suite asserts the vehicle row is **absent** rather than "coming soon". | `driver_app/test/features/profile/presentation/profile_screen_test.dart:336-346`; `driver_app/lib/config.dart:12` | low | [profile] |
| 4 | (Closed — server-backed rated rides landed) The "already rated" set is no longer session-local: `RatedRidesNotifier.build()` fetches `GET /driver/ratings` and exposes the tri-state `RatingStatus{rated,unrated,unknown}` where `unknown` never reads as `unrated` and only `unrated` can prompt. Loading/error surfaces with retry, `markRated` is optimistic, and `ref.onDispose` cancels the in-flight Dio request. History/Trip consume the tri-state, and the old shims/test-only setters (`ratedRideIdsProvider`, `ratedRideIdsNotifierProvider`, `ratedRideIdsSetProvider`, `setRatedIds`, `set rated`, `isRated(`, `orElse: () => false`) are gone from `driver_app`. | `driver_app/lib/features/rides/data/rated_rides_provider.dart:27,41,81,125,137`; `driver_app/lib/features/rides/data/rides_repository.dart:180`; `driver_app/lib/features/rides/presentation/rides_history_screen.dart:199,241,255`; `driver_app/lib/features/trip/presentation/trip_screen.dart:177,181` | resolved | [history] |
| 5 | No withdraw UI (`POST /driver/earnings/withdraw` is a stub) — **kept open**: no app work until the API implements it. Server design settled but **deferred**: `api_plans/[payout]_driver_earnings_and_withdraw.md` | `driver_app/lib/features/rides/presentation/rides_history_screen.dart:11-13` | low | [history] |
| 6 | `/vehicle` is reachable only by deep link: both the drawer and the profile card omit it while `vehicleFeatureEnabled` is false, and the card row was the app's only `context.push('/vehicle')` — flipping the flag re-adds the row with no other change. **Kept open** as an intentional gate | `driver_app/lib/features/navigation/driver_nav_items.dart:23`; `driver_app/lib/config.dart:12` | low | [profile] |
| 7 | (Fixed by `[nav]_app_wide_drawer.md`) The sidebar is no longer `/home`-only: a `ShellRoute` wraps the five top-level sections in one `DriverShell` Scaffold, so switching sections needs no back-press. `/trip` and `/safety` stay outside; `/safety` keeps its own back arrow. | `driver_app/lib/features/navigation/driver_shell.dart:26`; `driver_app/lib/core/router/app_router.dart:77-110`; `driver_app/test/features/navigation/driver_shell_test.dart` | resolved | [nav] |
| 8 | (Fixed by `01_[dispatch]_keepalive_and_offer_reliability.md`, landed/deleted) No driver-side keep-alive: `WebSocketService` now owns an opt-in `heartbeatInterval` loop (driver opts into 25 s via `webSocketServiceProvider`), armed on connect/`setOnline`, stopped on disconnect/dispose, and re-armed with an immediate `ping` on reconnect; `availability.onOnlineChanged = websocket.setOnline` keeps it in lockstep with the status switch and `websocket.onReconnected = () => publishLastPosition()` re-publishes the last fix. `isConnected` stays "open, not alive" by design (documented at `shared/lib/src/network/websocket_service.dart:62-70`). | `shared/lib/src/network/websocket_service.dart:37,112,148,177,204`; `driver_app/lib/core/network/websocket_service.dart:17,45,78`; `driver_app/lib/core/location/location_service.dart:245,249` | resolved | [dispatch] |
| 9 | (Closed — api bug #20 landed) The backend `POST /api/v1/feedback` now persists the client's `type` (`feedback.type`, migration `018`), so the app's `type:'app_issue'` is retained instead of silently ignored. The app already sent it, so no client change was needed. | `internal/handler/platform.go:118-145`; `internal/repository/feedback_repo.go:30`; `internal/database/migrations/018_push_pipeline.up.sql:31`; `driver_app/lib/features/safety/data/safety_repository.dart:26-34` | resolved | [safety] |
| 10 | Documented bound: the server-backed rated-rides walk stops at `ratedRidesMaxPages` (20) × `ratedRidesPageSize` (50) = 1000 newest ratings, because the server clamps `per_page` to ≤50 and offers no cursor. A driver with >1000 submitted ratings could have an older already-rated ride read as `unrated` (the loaded set is then the truth) and be prompted again. Low severity until real volumes approach the bound; the fix is a cursor/`total`-driven fetch or an "I rated this" endpoint. Owned by `01_[history]_rated_pagination_past_cap.md` (shares the open `api_plans/[history]_rating_existence_endpoint.md` prerequisite with rider bug #11) | `driver_app/lib/features/rides/data/rated_rides_provider.dart:15,156`; `internal/handler/ride.go:436-438` | low | [history] |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `01_[history]_rated_pagination_past_cap.md` | history | `api_plans/[history]_rating_existence_endpoint.md` | Honest `unknown` past the 20 × 50 walk bound so an over-cap driver is never re-prompted (bug #10); resolve a specific ride via the open `ride_id`-filter prerequisite, or keep the app-only truncated⇒`unknown` fix (independent of it) |
| `[push]_device_token_registration.md` | push | landed `[push]` API pipeline (no open plan) | Register/refresh a device token and unregister on sign-out so fan-out stops reaching zero devices; seam-only (deferrable) until a real FCM/APNs provider is wired server-side |

All four earlier wave plans (`[profile]_profile_settings_tests.md`, `[safety]_sos_feedback.md`,
`01_[session]_switch_and_cancel_session.md`, `[nav]_app_wide_drawer.md`) landed and were deleted, and
the server-backed rated-rides work that closed bug #4 landed without a surviving plan file.

## Skip list (authoritative)

The single source of truth for "why isn't X in the driver app?". Each backend STUB is a hard
"do not build UI on this" (see Invariants); re-verify against `internal/router/router.go`
before loosening any row.

| Endpoint | Reason to skip / gate |
| --- | --- |
| `GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents` | Backend STUB (`router.go:139-142`) — gated in `[profile]` (bug #6) |
| `GET /driver/me/earnings`, `POST /driver/earnings/withdraw` | Backend STUB (`router.go:143,222`) — client-side derived in `[history]` (bug #5) |
| `GET /driver/ratings` | **No longer a stub** — real `rideHandler.GetRatings` (`router.go:203`, `ride.go:427-473`); app-side consumption landed and bug #4 is closed (the profile still carries `rating_summary`) |
| `GET /driver/rides/queue` | Stub returning an empty list (`platform.go:446-448`); offer push covers live demand |
| `GET /driver/rides/:id/rider` | Stub returning a hardcoded rider (`platform.go:459-461`) — real info arrives via `ride.updated` |
| `POST /driver/rides/:id/decline` (HTTP) | **Route exists but is mis-wired to the wrong handler**: `internal/router/router.go:155` binds it to `platformHandler.StubPayment` (`internal/handler/platform.go:499-504`), so it answers `200 {"status":"stub","message":"Payment integration pending"}` and **records no decline** — a copy-paste bug, not a missing route. The WS `decline` channel is the only working path today; file the backend ticket |
| `POST /driver/rides/:id/notify-arrival` | Real but redundant handler (`router.go:159` → `ArrivalNotification`, `platform.go:472-474`); the `PUT /:id/status` transition already notifies the rider, so no app UI is needed |
| Rider-side features (rides create, favorite places, payments, receipts, tip, promos, reviews of driver seen ahead) | Out of the driver's domain — the API's correct consumer is `rider_app` |
| Social login, verify-email/phone | `PARTIAL`/stub on backend; skip until backend completes |

## Invariants
- Tests use `mocktail` + `http_mock_adapter`, mirroring `driver_app/test/core/...`; never build UI on a backend STUB — the authoritative skip list is the section above.
- Don't remove public providers used by other screens; extend them. `core/auth/auth_provider.dart` is the single owner of session/token state.
- New shared symbols are imported from the barrel directly — do **not** add shims. `shared/` owns no route table and no `go_router` dependency.
- The ride-state machine owns the primary button; widgets never hold paging state.
- The five top-level sections are body-only and must not build their own `Scaffold`/`AppBar`; `DriverShell` owns the only one. `/trip` and `/safety` stay outside the shell and keep their own back affordance.
- The `/mnt/i/flutter` SDK has CRLF endings and is unusable; the working toolchain is the Linux FVM SDK at ~/fvm/default plus native Melos 8 at ~/.pub-cache/bin/melos (`export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH` then `melos run analyze`/`melos run test`). The `make flutter-*` targets shell out to the Windows `melos.bat` and are broken from this WSL tree.

## Verification
```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK (the /mnt/i/flutter SDK has CRLF endings)
melos run analyze
melos run test
```
Last verified 2026-10-03: `flutter analyze` → No issues found; `flutter test` → 288 tests passed across 28 files (driver_app only, run from `driver_app/` with the Linux FVM SDK). Full-workspace `melos run analyze`/`melos run test` not re-run this pass.
