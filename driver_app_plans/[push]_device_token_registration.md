---
tag: push
depends_on: []
status: open
---

# [push] Device-token registration

## Current state

The API push pipeline **landed** (`api_plans/STATUS.md` → Landed `[push]`), but the driver app
never registers a token, so fan-out reaches zero devices:

- `POST /api/v1/devices` (alias `/device-tokens`) → `PlatformHandler.DeviceRegister` —
  `internal/handler/platform.go:164`; body `deviceRegisterRequest{Token, Platform}` with
  `binding:"required,oneof=ios android web"` — `internal/handler/platform.go:72-75`
- `DELETE /api/v1/devices/:token` (alias `/device-tokens/:token`) → `DeviceUnregister` (204,
  idempotent, user-scoped) — `internal/handler/platform.go:198`
- routes — `internal/router/router.go:271-276`
- repo: upsert/reassign on globally-unique token `internal/repository/device_token_repo.go:49`;
  user-scoped unregister `:69`; `ListActiveTokens` `:77`
- provider seam: default `LogProvider` is a credential-free no-op `internal/service/push/provider.go:40`;
  `MultiProvider` is the real FCM/APNs seam `:60`; `maskToken` `:77`; `NotifyUser` returns void
  (`internal/service/push/service.go:43`)

Driver app state:

- **No** device/push references anywhere in `driver_app/lib`; `ApiEndpoints` has no device path
  (`driver_app/lib/core/api/endpoints.dart:6-49`).
- Sign-out has **two** entry points, both calling the session owner directly:
  `driver_app/lib/features/settings/presentation/settings_screen.dart:63` and
  `driver_app/lib/features/navigation/driver_shell.dart:95`; shared flow
  `shared/lib/src/settings/app_sign_out.dart:48`.
- **Ordering trap:** `AppAuthController.logout()` does `apiClient.setToken(null)` and clears tokens
  **before** `onLoggedOut()` — `shared/lib/src/auth/app_auth_controller.dart:287-290`. Unregistering
  inside `onLoggedOut()` would fire unauthenticated (401) and never reach the server. The unregister
  must run while the access token is still installed.
- Availability seam already exists: `AvailabilityNotifier.onOnlineChanged` is wired to the WS
  heartbeat in `driver_app/lib/core/location/location_service.dart:245`; do not clobber that wiring.
- No `firebase`/`messaging` dependency in any `pubspec.yaml`. Even after registration, production
  delivery is **inert** until a real `MultiProvider` (FCM/APNs) is installed server-side — the
  default is `LogProvider` (`internal/router/router.go:97`).

**Claim correction:** the task's "sender `type`" is not a field in this contract. The register body
has **no `type`**; the required discriminator is `platform` (`ios|android|web`) and a blank/other
value is a 422 (`platform.go:74`). The server sets `Data["type"]="ride.updated"` in outbound push
payloads (`internal/service/ride.go:62`); the client never sends it. This plan therefore requires a
non-blank **`platform`**, not a `type`.

## Scope

Seam-filling and deferrable: this makes the pipeline reachable, but it delivers nothing until the API
provider is real. Design it so the plugin is behind a testable seam and `melos analyze`/`test` stay
green without Firebase credentials.

1. **SDK decision + seam.** Use `firebase_messaging` (FCM) as the single SDK for android/ios/web.
   Wrap it behind a thin `PushTokenSource` interface with a Riverpod `pushTokenSourceProvider`
   (`getToken()` + a token-refresh stream). The production binding is a `FirebaseMessagingTokenSource`;
   the harness/tests use a fake. Derive `platform` from `defaultTargetPlatform` →
   `'android' | 'ios' | 'web'` (never blank). If adding the plugin now is undesirable, ship only the
   seam + a no-op source and defer the binding — explicitly a deferred plan.
2. **Registration triggers.** A `PushRegistrationService` observes the authenticated driver session
   and `availabilityProvider.online`; on either becoming true it requests a token and
   `POST /api/v1/devices {token, platform}` (idempotent upsert). Also re-register on the SDK's
   token-refresh stream. This covers sign-in and the online toggle without touching the existing
   `onOnlineChanged` heartbeat wiring. Add `ApiEndpoints.devices` / `deviceUnregister(token)`.
3. **Unregister on sign-out.** Override `logout()` in the driver `AuthNotifier`
   (`driver_app/lib/core/auth/auth_provider.dart`) to best-effort `DELETE /api/v1/devices/{token}`
   **before** `super.logout()` clears the token, then call `super.logout()`. This single seam covers
   both UI sign-out call sites and the `switchAccount` → `cancelCurrentSession` path. Must never
   block or fail sign-out.
4. **Secrecy.** Never log the raw token or put it in an error message; if a masked form is needed,
   reuse the API's convention (`provider.go:77`). No `debugPrint(token)`.

## Invariants carried in

- Registration failure is non-fatal to auth and to the online/offline toggle: all calls are
  best-effort and swallowed; they never gate `logout()`, `setOnline()` or routing.
- Unregister on sign-out so a reassigned device does not keep the old account's notifications
  (the globally-unique token already reassigns on re-register; unregister is defense in depth for a
  sold/handed-off device).
- Never log the raw token.
- `platform` must be non-blank and in `ios|android|web` (server `oneof`, `platform.go:74`).
- Do not break the WS heartbeat: `availability.onOnlineChanged = websocket.setOnline`
  (`location_service.dart:245`) stays; push registration observes availability separately.
- `core/auth/auth_provider.dart` remains the single owner of session/token state; no `shared/`
  change.

## Cross-domain notes

- The rider app mirrors this and has no device registration either (`rider_app_plans/STATUS.md`
  Devices/push row). On a shared device the last registrant wins, by design of the globally-unique
  token.
- API prerequisite/follow-up (not a regression): production delivery stays inert until a real
  `MultiProvider` (FCM/APNs credentials/clients) is wired server-side — `api_plans/STATUS.md`
  `[push]` follow-up, `internal/router/router.go:97`. Registering tokens is necessary but not
  sufficient; this plan is therefore deferrable.
- `depends_on` is `[]`: it consumes already-landed `[push]` API capability; no open api plan exists.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

Expected new coverage: a fake `PushTokenSource` drives a registration test that pins
`POST /devices` URL + `{token, platform}` body; registration failure leaves the session and online
toggle unaffected; `logout()` issues the unregister **before** the token is cleared and still
completes when the unregister 401s/throws; the token never appears in captured logs or error text.
