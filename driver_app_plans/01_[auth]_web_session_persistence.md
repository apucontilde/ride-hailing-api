---
tag: auth
depends_on: ["rider_app_plans/[auth]_web_session_persistence.md"]
status: open
---

# Driver adoption & verification of the shared web session-persistence fix

> Dependent plan. The implementation lives in the **rider/shared** plan
> `rider_app_plans/[auth]_web_session_persistence.md` (phases: controller robustness, web storage
> adapter, shared tests, dev port). **This plan must not duplicate that code work.** Its whole scope
> is the driver-specific acceptance/verification of the shared fix and the driver-only test
> additions. Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test`.

## Why the driver is in scope

Both apps subclass the **same** shared controller (`shared/lib/src/auth/app_auth_controller.dart`)
and storage (`shared/lib/src/auth/auth_storage.dart`). The rider-web bug being fixed Flutter-only in
`shared/` is therefore a driver bug too — the driver app inherits the identical class of failure. The
driver app is the one that also does push-token cleanup on `logout()`, so the semantics change
(definitive vs transient) must be checked against that override.

## Root cause (shared — cited, not duplicated)

Implementation is owned by `rider_app_plans/`. The driver plan only records the shared evidence:

- **Eager logout on transient errors.** `checkAuth()` probes `/me` and on *any* exception runs
  `webSocketService.disconnect()` → `authStorage.clearTokens()` → `apiClient.setToken(null)` →
  `AuthState()` — `shared/lib/src/auth/app_auth_controller.dart:101-124`, specifically the
  `catch (_)` branch at `:114-119`. A Dio timeout / dropped connection is treated exactly like an
  expired or revoked token.
- **No cold-start refresh when only a refresh token exists.** `checkAuth` reads the access token
  (`:102`); with none it goes straight to unauthenticated and never tries the stored refresh token
  (`:120-123`). With an access token present, an expired one is refreshed by the 401 interceptor
  (`shared/lib/src/api/api_client.dart:40-73`), but a **transient** refresh failure then calls
  `logout()` (`shared/lib/src/auth/app_auth_controller.dart:248-272`, the `catch (_)` at
  `:268-271`) and destroys a still-valid refresh token.
- **Web storage backend.** `AuthStorage` always constructs a bare
  `const FlutterSecureStorage()` with no platform options — `shared/lib/src/auth/auth_storage.dart:1,6-7`.
  On web this is the storage backend (or lack of one) under the rider fix. The driver consumes the
  same class through the shim `driver_app/lib/core/auth/auth_storage.dart:1` and therefore inherits
  the fix, plus inherits its risk.

The shared fix's correct behavior (defined by the rider plan) is the contract this plan verifies:
**definitive** auth failures (400/401 — a dead/revoked refresh token) sign out; **transient**
failures (timeout, connection, 5xx, malformed body) preserve tokens and the session. A **403** from
`/driver/me` stays the existing `onForbiddenProfile` path (keeps the session for onboarding), not a
sign-out.

## Driver-specific surfaces this plan touches

No driver source change is planned unless verification finds a driver-side gap. The code that must
keep working with the new semantics:

- `AuthNotifier.logout()` override — unregisters the push token **before** `super.logout()` clears
  the bearer: `driver_app/lib/core/auth/auth_provider.dart:77-90` (the call at `:85`,
  the swallow at `:86-88`, `super.logout()` at `:89`).
- `AuthNotifier.onAuthenticated()` — registers the push token on every authenticated transition
  (login/registration/cold-start `/me`) and seeds the driver profile:
  `driver_app/lib/core/auth/auth_provider.dart:49-67`.
- `AuthNotifier.onLoggedOut()` — clears the cached driver profile (incl. `status: online`):
  `driver_app/lib/core/auth/auth_provider.dart:69-74`.
- The 401 refresh seam is wired at
  `driver_app/lib/core/auth/auth_provider.dart:150-161` (`unauthorizedHandler` at `:159`); the
  interceptor that invokes it is `shared/lib/src/api/api_client.dart:47-73` (auth endpoints excluded
  at `:51-53`).
- Driver storage shim: `driver_app/lib/core/auth/auth_storage.dart:1`.
- Cold-start bootstrap: `driver_app/lib/features/auth/presentation/splash_screen.dart:20-31`
  (`checkAuth()` then route to `/home` / `/onboarding` / `/login`); router redirect
  `driver_app/lib/core/router/app_router.dart:31-52`; `main()` `driver_app/lib/main.dart:5-8`.
- Push device-token service (register/unregister, availability trigger): provider
  `driver_app/lib/core/push/device_token_service.dart:108-124`, `register()` `:53-62`,
  `registerToken()` `:65-76`, `unregister()` `:81-90`; materialized for the app lifetime at
  `driver_app/lib/app.dart:21`.

## Scope (driver-only)

### 1. Acceptance / verification matrix (manual or e2e, driver app)

Run the driver app on **web** against the API after the shared fix lands. Confirm each row; the
rider plan defines the shared behavior, this plan only verifies it from the driver bootstrap, which
differs (role gating + push cleanup).

| # | Scenario | Expected under new semantics | Driver evidence |
| --- | --- | --- | --- |
| A1 | Cold start web with valid stored access+refresh → driver role | Lands authenticated on `/home`, no re-login; push re-registered | `splash_screen.dart:20-31`, `auth_provider.dart:49-67` |
| A2 | Cold start web with an **expired access** + valid refresh | Session restored without showing `/login` (401 interceptor refreshes, then `/me` retries); push re-registered | `api_client.dart:54-73`; `auth_provider.dart:159` |
| A3 | Cold start web with **no access token but a valid refresh token** | Recovers by refreshing **first**, then `/me`; no `/login`; push re-registered | shared fix (`checkAuth` refresh-first branch); `auth_provider.dart:49-67` |
| A4 | Cold start web with a **transient** probe/refresh failure and tokens present | **Not** signed out: tokens preserved, session not silently dropped; a retry recovers | shared fix; verify no `clearTokens`/`unregister` |
| A5 | Cold start web with a **definitive** failure (400/401 / revoked refresh) | Signed out to `/login`; tokens cleared locally | shared fix; `app_auth_controller.dart:112-119` |
| A6 | Manual sign-out (settings or shell drawer) | Push token `DELETE` fires **before** the bearer clear; profile cache cleared | `auth_provider.dart:77-90`, `device_token_service.dart:81-90` |
| A7 | Mid-session 401, refresh **transient** failure | Stays authenticated, no push unregister, stored tokens intact; the failed call surfaces an error | `api_client.dart:54-73`, `auth_provider.dart:159` |
| A8 | Mid-session 401, refresh **definitive** failure | Signs out; push token unregistered before bearer clear | `app_auth_controller.dart:268-271`; `auth_provider.dart:77-90` |

`onLoggedOut` must still null the profile on every real sign-out (A5/A6/A8) and must **not** run on
A4/A7 (no sign-out) — otherwise the online `status` leaks into the next session
(`auth_provider.dart:69-74`).

### 2. Driver-only test additions

Add to `driver_app/test/core/auth/auth_provider_test.dart` (reuse its `MockDeviceTokenService`,
`MockApiClient`/`MockDio`, `MockAuthStorage` setup at `:14-46`; the logout group starts at `:263`).
These assert the driver **hook** behavior against the new controller contract; the shared controller
semantics themselves are tested in the rider/shared plan.

- **Transient refresh keeps the session and does not unregister** — stub
  `dio.post(ApiEndpoints.refreshToken)` to throw a `DioException` whose `type` is a connection
  timeout; assert `refreshToken()` returns `false`, `state.status` stays authenticated,
  `verifyNever(deviceService.unregister)`, `verifyNever(storage.clearTokens)`.
- **Definitive refresh signs out and unregisters before clearing** — stub the refresh POST with a
  401; assert `unregister()` called once, `clearTokens()` called once, and
  `verifyInOrder([unregister, setToken(null)])` (mirrors the existing order test at
  `auth_provider_test.dart:335-338`).
- **Transient cold-start probe preserves tokens** — `storage.getAccessToken() → 't'`,
  `dio.get('/driver/me')` throws a connection error; under the shared fix assert tokens are **not**
  cleared and the push token is **not** unregistered.
- **Cold-start recovery from a refresh token alone** — `storage.getAccessToken() → null`,
  `storage.getRefreshToken() → 'r'`; the refresh POST succeeds and the subsequent `/driver/me`
  returns the driver JSON; assert authenticated driver state and that `onAuthenticated` registered
  the push token (A3).
- **A storage read throw does not crash or sign out** — `storage.getAccessToken()` /
  `getRefreshToken()` throw; assert `checkAuth()` / `refreshToken()` complete, do not throw, and do
  not unregister the push token (shared fix's storage-error degradation).
- **Definitive cold-start probe clears** — `dio.get('/driver/me')` throws
  `UnauthorizedException`; assert `clearTokens()` called once (the existing
  `'clears session when driver fetch fails'` test at `:100-111` must be updated to the new
  discrimination rather than deleted — it currently pins the old eager behavior).
- **Interceptor-driven refresh on a real `ApiClient`** — extend
  `driver_app/test/core/api/api_client_test.dart` (it already uses `http_mock_adapter` at `:1-17`):
  a 401 from a non-auth path invokes `unauthorizedHandler`; a handler that returns `false` leaves
  `apiClient`/session usable (no forced logout is issued by the client itself).

Keep existing suites green: `driver_app/test/core/auth/auth_provider_test.dart` logout group
(`:263-364`, incl. unregister-before-clear `:303` and throwing-unregister `:341`),
`driver_app/test/core/auth/auth_storage_test.dart`, and the shared
`shared/test/auth/app_auth_controller_test.dart`.

### 3. Web cold-start check

The driver's web bootstrap is `main()` → `ProviderScope` → `DriverApp` → `SplashScreen.checkAuth()`
(`driver_app/lib/main.dart:5-8`, `driver_app/lib/app.dart:9-38`,
`driver_app/lib/features/auth/presentation/splash_screen.dart:20-31`). Verify a **page reload** on
web keeps the session (A1/A2): the fix is only observable if the storage adapter actually persists
tokens across a reload. Where the shared plan's web adapter exposes a test seam, the driver may
assert it through the `driver_app/lib/core/auth/auth_storage.dart` shim; otherwise this stays a
manual/e2e check (no driver `integration/` runner exists — `driver_app/integration` is absent).

## Explicitly delegated to the rider/shared plan (do NOT duplicate)

- Any change to `shared/lib/src/auth/app_auth_controller.dart` (definitive-vs-transient
  classification, cold-start refresh/preserve branch).
- Any change to `shared/lib/src/auth/auth_storage.dart` (web storage adapter, key persistence).
- Shared `AuthStorage` / controller tests (`shared/test/auth/app_auth_controller_test.dart`).
- The rider-web dev port and rider-side acceptance.

If verification exposes a **driver-only** gap (e.g. the `logout()` override must unregister on a new
code path), fix it in a follow-up driver plan — record it as a `STATUS.md` known bug first, per the
skill.

## Invariants

- **No driver code change is the default outcome.** If none is needed, this plan lands as a pure
  verification record + tests.
- **The driver `logout()` override stays the single unregister seam**
  (`driver_app/lib/core/auth/auth_provider.dart:77-90`): unregister while the bearer is still
  installed, swallow failure, then `super.logout()`. Never move it into `onLoggedOut()`, which runs
  after `setToken(null)`.
- **Transient ⇒ no sign-out ⇒ no unregister.** A transient failure must not reach `logout()`,
  or the driver loses push delivery for a session that is still valid.
- **Definitive ⇒ sign-out ⇒ unregister-before-clear.** Preserve the existing ordering guarantee.
- **No shims.** Continue importing shared symbols from the barrel; if the shared fix adds a symbol,
  import it directly (AGENTS.md re-export rule).
- **Toolchain.** Use the Linux FVM SDK + native Melos 8 (the `/mnt/i/flutter` SDK has CRLF endings;
  `make flutter-*` shells out to broken Windows `melos.bat`): `melos run analyze` + `melos run test`.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

Re-count test totals at landing; the README/`STATUS.md` totals drift after post-audit commits.

## Cross-domain notes

- **Rider/shared:** `depends_on` / prerequisite for the actual fix —
  `rider_app_plans/[auth]_web_session_persistence.md`. Watch its phase-3 tests for the exact
  definitive-vs-transient predicate this plan asserts against; if the predicate changes, reconcile
  the driver tests in §2.
- **API:** none. The error contract is unchanged; the fix is client-side discrimination only.

## STATUS.md rows to update on landing

- Add a one-line `### [auth]` Landed entry: the driver inherits the shared web
  session-persistence fix; the `logout()` push-unregister seam still holds under
  definitive-vs-transient semantics; cite the verified `driver_app` `file:line` + the new test file.
- Remove this plan's row from Open plans and delete this file (git history is the archive).
- No new known-bug row unless a genuine driver-side gap is found during verification.
