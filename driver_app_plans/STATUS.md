# driver_app — Status

> Make `driver_app/` really drive every driver-facing capability the API offers. Owner: `driver-planner`. Verify: `make flutter-analyze` + `make flutter-test`.

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

## Known bugs & issues

| # | Issue | Evidence | Severity | Owner |
| --- | --- | --- | --- | --- |
| 1 | `appPermissionProvider` is read but never written (`requestPermission()` omits it), so the "denied" banner can never fire | `driver_app/lib/core/location/location_service.dart:30,106`; `driver_app/lib/features/home/presentation/home_screen.dart:47,82` | medium | [online] |
| 2 | `lastLocation` is stored but has no consumer (server pushes `driver.location` only to the rider) | `driver_app/lib/core/ride/ride_state_notifier.dart:17,76` | low | [ws] |
| 3 | Onboarding collects first/last name but never `PUT /driver/me` | `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:44` | medium | [profile] |
| 4 | Plan-06 shipped profile/vehicle/settings code has ZERO tests (no `driver_app/test/features/{profile,settings,vehicle}/`) | `driver_app/test/features/` | medium | [profile] |
| 5 | "Already rated" set is session-local (`GET /driver/ratings` is a stub) | `driver_app/lib/features/rides/presentation/rate_sheet.dart:14` | low | [history] |
| 6 | No withdraw UI (`POST /driver/earnings/withdraw` is a stub) | `driver_app/lib/features/rides/presentation/rides_history_screen.dart:11-13` | low | [history] |
| 7 | Redundant authenticated branches in `app.dart` (both only call `service.start()`) | `driver_app/lib/app.dart:18-23` | low | [online] |
| 8 | Prior README test total was stale at HEAD (171 vs 179 actual) — re-count, do not reuse old numbers | `grep -rhE "^\s*(test\|testWidgets)\(" driver_app/test` = 179 | low | — |

## Open plans

| File | Tag | Depends on | What remains |
| --- | --- | --- | --- |
| `[profile]_profile_settings_tests.md` | profile | none (screens landed) | 3 missing test suites + onboarding name persistence via `PUT /driver/me` |
| `[safety]_sos_feedback.md` | safety | none (landed 01/02 only) | `safety_screen.dart` + `safety_repository.dart` + settings entry tile + tests; authoritative skip list |

## Invariants
- Tests use `mocktail` + `http_mock_adapter`, mirroring `driver_app/test/core/...`; never build UI on a backend STUB — the authoritative skip list is in `[safety]_sos_feedback.md`.
- Don't remove public providers used by other screens; extend them. `core/auth/auth_provider.dart` is the single owner of session/token state.
- The ride-state machine owns the primary button; widgets never hold paging state.
- Dart CLI is broken in this WSL harness — verify with `make flutter-analyze` / `make flutter-test`, never `flutter`/`dart` directly.

## Verification
```bash
make flutter-analyze
make flutter-test
```
