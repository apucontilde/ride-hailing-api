---
tag: push
depends_on: []
status: open
---

# [push] Rider device-token registration (seam-filling; may be deferred)

## Current state (verified 2026-10-04)

**Server side is landed** (`api_plans/STATUS.md` → Landed `[push]`):
- `POST /api/v1/devices` (alias `POST /api/v1/device-tokens`) → `internal/handler/platform.go:164`
  `DeviceRegister`; body `{token, platform}` with `platform` `oneof=ios android web`
  (`platform.go:72-75`); answers `201 {message, device}`.
- `DELETE /api/v1/devices/:token` (alias `.../device-tokens/:token`) → `platform.go:198`
  `DeviceUnregister`; `204`, idempotent, user-scoped.
- Routes `internal/router/router.go:271-276`. A token is globally unique and **reassigns** to the
  account that registers it last (`platform.go:150-153`; `api_plans/STATUS.md:203-216`).
- The default push provider is a `LogProvider` safe no-op; production delivery is **inert** until
  real FCM/APNs credentials/clients exist (`api_plans/STATUS.md:207-216`).

**App side is absent:**
- `rider_app/lib/core/api/endpoints.dart:1-33` has **no** device / device-token constants.
- No push SDK is declared in `rider_app/pubspec.yaml` (nor `shared/pubspec.yaml`), so no token is
  ever acquired or registered.
- `AuthNotifier.onLoggedOut()` (`rider_app/lib/core/auth/auth_provider.dart:62-67`) only clears
  `riderProfileProvider`; nothing unregisters a device token.
- Sign-out path: `rider_app/lib/features/settings/presentation/settings_screen.dart:60-67`
  `performAppSignOut(..., onSignOut: () => ref.read(authProvider.notifier).logout(), ...)`; the
  drawer has the same call at `rider_app/lib/features/navigation/rider_shell.dart:80`. Shared
  `logout()` (`shared/lib/src/auth/app_auth_controller.dart:274-291`) disconnects the WS, POSTs
  `/auth/logout`, clears tokens, then calls `onLoggedOut`. The bearer is gone by then, so an
  authenticated `DELETE /devices/:token` must run **before** `logout()`.

Net: the API seam exists but the rider app never registers, so delivery reaches zero devices.

## Scope

Fill the rider half of the seam (expected to be **deferred** until a real push provider is wired
server-side):

1. **SDK + platform.** Add `firebase_messaging` (or the chosen SDK) to `rider_app/pubspec.yaml`;
   platform setup (Android `google-services.json`, iOS APNs entitlement) is out of harness scope.
   Compute `platform` as `kIsWeb ? 'web' : Platform.isIOS ? 'ios' : 'android'` (guard `dart:io`
   for web). The API **rejects a blank/unknown platform `422`** (`platform.go:74`), so sending
   nothing or an empty string is not acceptable.
2. **Endpoints.** Add to `rider_app/lib/core/api/endpoints.dart`:
   `devices = '$prefix/devices'` and `deviceByToken(token) => '$prefix/devices/$token'`
   (URL-encode the token in the path). Pick one path (`/devices`) and use it consistently; the
   `/device-tokens` alias is served too (`router.go:271-276`).
3. **Service.** Add a `DeviceTokenService` with an app-local provider wired like
   `LocationPingService` (`features/home/data/location_ping_service.dart:10,84`): request
   notification permission, `getToken()`, `POST /devices {token, platform}`, subscribe to
   `onTokenRefresh` and re-register the new token. Registration is **best-effort and non-fatal** —
   a failure must not block login or the ride flows.
4. **Login / account switch.** Register on the authenticated transition
   (`AuthNotifier.onAuthenticated`, `auth_provider.dart:53-60`) so the token reassigns to the
   current account. Reassignment means the previous account stops receiving pushes; the app must
   still unregister on sign-out (below).
5. **Sign-out.** Unregister while the bearer is still valid, then log out. Extend the app's
   sign-out call site — e.g.
   `onSignOut: () async { await ref.read(deviceTokenServiceProvider).unregister(); await ref.read(authProvider.notifier).logout(); }`
   in `settings_screen.dart:60-67` (and `rider_shell.dart:80`). Do **not** put it only in
   `onLoggedOut()`: that runs after `logout()` clears the token
   (`app_auth_controller.dart:287-290`) and the DELETE would `401`.
6. The driver app mirrors this (`driver_app/`) — a cross-app follow-up for `driver-planner`, not
   part of this plan. A shared `DeviceRegistrar` could live in `shared/` (pure core, endpoints
   injected), but the app still owns the provider wiring — follow the existing
   `ApiClient(baseUrl:)` parametrization convention and never move app files into `shared/`.

## Invariants carried in

- Registration failure is **non-fatal** to auth and to ride flows.
- A token moved to another account must not keep the old account's notifications: the API
  guarantees reassignment (`platform.go:150-153`), and the app must still unregister on sign-out.
- **Never log the raw token.**
- Leave the re-export-shim structure intact: never move app files into `shared/`; new shared
  symbols import straight from the barrel.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Widget/unit tests: mock the push SDK; assert register is called with a valid platform and the
token, a token refresh re-registers, a registration failure does not surface as an auth error,
and sign-out calls unregister **before** `logout()`. No test may assert a logged raw token.

## Cross-domain notes

- API `[push]` is landed; **no open `api_plans/` prerequisite**. The server half is inert until
  real FCM/APNs clients/credentials exist (`api_plans/STATUS.md:212-216`) — this plan is
  seam-filling and may stay deferred.
- Driver app: same gap; `driver-planner` owns the mirror.
