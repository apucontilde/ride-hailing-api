---
tag: auth
depends_on: []
status: open
---

# [auth] Web session persistence — stop clearing the session too eagerly

> Independent plan. **Flutter-only** (one `shared/` change consumed by rider + driver); no API,
> server, routing, or driver-app change. Cite `file:line` evidence; verify with
> `melos run analyze` + `melos run test` (Linux FVM SDK, see Verification).
> Owner: `rider-planner`. Shared core is consumed by both apps — coordinate with the parallel
> `driver_app_plans/01_[auth]_web_session_persistence.md`, which must **reference this plan for the
> shared core and only cover driver-specific wiring/tests**.

## Goal

On the rider **web** app, a page refresh (cold start) must keep the signed-in session and land on
`/home` whenever a valid refresh token exists — instead of bouncing to `/login`. The shared
`AppAuthController` must distinguish **definitive** auth failures (401 / invalid refresh) from
**transient** ones (network blip, timeout, 5xx, malformed body) and must never destroy a recoverable
session, and on web the token store must actually survive a reload.

Concretely:

1. `checkAuth()` only clears tokens on a **definitive** auth failure; a transient error keeps them.
2. Cold start with a **refresh token but no access token** recovers by refreshing first.
3. `refreshToken()` never calls `logout()` (server revoke) on a transient failure.
4. A storage error never throws out of `login()` / `checkAuth()` / `refreshToken()`.
5. On web the store is a backend that survives a reload (using a browser-native store rather than
   `flutter_secure_storage`, whose web implementation requires a secure context and is not
   XSS-proof).

## Current state (verified)

All line numbers verified against the tree on 2026-10-06.

| Claim | Evidence |
| --- | --- |
| `AuthStorage` is a thin wrapper over `flutter_secure_storage` 10.0.0; every method awaits it directly | `shared/lib/src/auth/auth_storage.dart:1,4-7,13-52`; dep `shared/pubspec.yaml:16` |
| `checkAuth` catches **every** non-`ForbiddenException` error and clears both tokens + state | `shared/lib/src/auth/app_auth_controller.dart:114-119` |
| Cold start with **no access token** never attempts a refresh — it just disconnects and goes unauthenticated | `app_auth_controller.dart:120-123` |
| `checkAuth` reads the access token **outside** its `try` → a storage throw escapes | `app_auth_controller.dart:102` |
| `refreshToken` reads the refresh token **outside** its `try` → a storage throw escapes | `app_auth_controller.dart:249` |
| `refreshToken` calls `logout()` (server revoke) on **any** failure | `app_auth_controller.dart:268-271` |
| `login` catches only `ApiException` / `DioException`; `await authStorage.saveTokens` is inside the `try` but a storage throw matches neither → escapes to the UI | `app_auth_controller.dart:198-201,209,214` |
| Error interceptor already refreshes on 401 via `unauthorizedHandler` and retries once; `/auth/*` endpoints are excluded | `shared/lib/src/api/api_client.dart:40-73` (exclusion `:51-53`) |
| Interceptor still maps every status to a typed `ApiException` in `DioException.error` (so 401→`UnauthorizedException`, 400→`BadRequestException`, 500→`ServerException`, 403→`ForbiddenException`) | `api_client.dart:75-91`; `shared/lib/src/api/api_exceptions.dart:41-97` |
| Rider wires `unauthorizedHandler = notifier.refreshToken` | `rider_app/lib/core/auth/auth_provider.dart:147-149` |
| Rider `onForbiddenProfile()` **clears** the session (403 from `/rider/me` = not a rider) | `rider_app/lib/core/auth/auth_provider.dart:96-101` |
| Driver relies on the **default** `onForbiddenProfile()` (keeps a session so onboarding can promote the account) — the shared change must preserve this hook | `app_auth_controller.dart:94-99`; `driver_app/lib/core/auth/auth_provider.dart` has no override |
| Splash drives the cold start and routes to `/login` whenever `checkAuth` leaves the state unauthenticated | `rider_app/lib/features/auth/presentation/splash_screen.dart:21-37` |
| Access TTL 15 m, refresh TTL 720 h — a reload 15 m after login is a normal refresh path, not an expired session | `internal/config/config.go:195-196` |
| No `kIsWeb` / `package:web` / conditional import exists anywhere in `shared/lib` today | grep over `shared/lib` (only hit is `web_socket_channel` in `network/websocket_service.dart:3`) |

### Root cause

The session is destroyed by the **controller**, not by the store:

1. `checkAuth()` (`:114-119`) treats a connection error / timeout / 5xx / parse failure exactly
   like an invalid session: `clearTokens()` + `setToken(null)` + unauthenticated. A page reload that
   races the API (or hits one transient blip) wipes a perfectly valid 720 h refresh token.
2. The 401 interceptor calls `refreshToken()`; on a transient refresh failure `refreshToken()`
   calls `logout()` (`:268-271`), which revokes server-side and clears locally. So even the
   "transparent" path signs the user out on a blip.
3. With the access token already gone (e.g. cleared by (1)), `checkAuth` (`:120-123`) never tries the
   still-valid refresh token.
4. A storage exception (e.g. `flutter_secure_storage_web` on a problematic origin, or a platform
   channel error) can propagate out of `login` / `checkAuth` / `refreshToken` (`:102,:198-201,:249`).

Secondary (web): `flutter_secure_storage`'s web backend uses WebCrypto and requires a secure
context; `http://localhost` is one, but it is not XSS-proof and does not survive every same-origin
reconfiguration. This plan replaces it with `window.localStorage` on web (behind a conditional
import, see Phase 2) and wraps every access so a storage failure degrades to an in-memory session
instead of a crash or a forced re-login.

## Scope

### Phase 1 — session robustness (`shared/lib/src/auth/app_auth_controller.dart`)

**1a. Error classification helper.** Add a small pure helper, e.g.

```dart
bool _isDefinitiveAuthFailure(Object error) {
  final api = switch (error) {
    ApiException() => error,
    DioException(error: final Object? mapped) when mapped is ApiException => mapped,
    _ => null,
  };
  final code = api?.statusCode;
  return code == 400 || code == 401;
}
```

- Definitive = 400/401 (a dead/invalid refresh token, an expired session the server rejects).
- Transient = everything else: timeout, connection error, 5xx (`ServerException`), 429, malformed
  body / parse error.
- 403 is deliberately **not** classified here: it is role, not token validity, and is handled by the
  existing `onForbiddenProfile()` hook (rider clears, driver keeps).

**1b. `refreshToken()` — no logout storm, single-flight.** Restructure to:

```dart
Future<bool>? _refreshInFlight;

Future<bool> refreshToken() =>
    _refreshInFlight ??= _doRefresh().whenComplete(() => _refreshInFlight = null);

Future<bool> _doRefresh() async {
  final stored = await authStorage.getRefreshToken(); // hardened → null on failure
  if (stored == null) return false;
  try {
    // POST refreshTokenEndpoint, saveTokens, setToken, connect ws, return true
  } catch (e) {
    if (_isDefinitiveAuthFailure(e)) {
      await _clearLocalSession(); // local only — the token is already dead server-side
    }
    return false; // transient: keep access + refresh tokens
  }
}
```

- **Never** call `logout()` from the failure path — no server-revoke storm, no wipe on a blip. On a
  definitive failure clear locally (see `_clearLocalSession`) so a dead token cannot loop.
- The single-flight guard coalesces the interceptor's `unauthorizedHandler!()` call
  (`api_client.dart:58`) with an explicit `checkAuth` call, closing the existing double-refresh
  window.

**1c. `_clearLocalSession()` — local teardown that still runs hooks.**

```dart
Future<void> _clearLocalSession() async {
  await webSocketService.disconnect();
  apiClient.setToken(null);
  await authStorage.clearTokens();      // hardened: never throws
  state = const AuthState();
  await onLoggedOut();                  // app cache cleanup (rider/driver override)
}
```

This is the definitive-failure path. `logout()` (server revoke + local clear) stays as-is for
user-initiated sign-out and `switchAccount`.

**1d. `checkAuth()` — recover, don't panic.** Read both tokens up front; branch:

- **No access AND no refresh token** → disconnect, `state = const AuthState()` (nothing to recover).
- **No access, refresh present** → `await refreshToken()` first; on success continue to `/me`, on
  failure fall through to a non-destructive unauthenticated state (tokens retained).
- **Access present** → `apiClient.setToken(access)`, then `fetchMe()`.
- `on ForbiddenException` → `await onForbiddenProfile()` (preserve the hook exactly).
- `on UnauthorizedException` → `await refreshToken()` (single-flight; may coalesce with the
  interceptor's attempt) then retry `fetchMe()` **once**. If it still fails, apply the
  definitive/transient rule below.
- **Any other error** → `_isDefinitiveAuthFailure(e) ? _clearLocalSession() : keep tokens` and set a
  non-destructive unauthenticated state; do **not** clear storage.

On the success path keep the existing side effects: `state = AuthState(authenticated, user)`,
`onAuthenticated(user)`, and `webSocketService.connect` when `shouldConnectWebSocket(user)`.

Non-destructive unauthenticated state = `state = const AuthState()` (status unauthenticated) **with
storage untouched**, so a later retry / in-session 401 can recover. The splash then routes to
`/login` for this launch but the tokens survive for the next attempt; call this out in the splash
plan note (Phase 3) if a retry affordance is desired (see open decisions).

**1e. Harden `login` / storage writes.** Wrap `await authStorage.saveTokens(...)`
(`:198-201`) in its own `try/catch` so a storage failure is best-effort: log/ignore and keep the
in-memory token (`apiClient.setToken` at `:197` already ran) and the authenticated state. Never let
a storage throw escape `login`.

### Phase 2 — reliable web persistence (`shared/lib/src/auth/auth_storage.dart`)

Replace the direct `FlutterSecureStorage` field with a tiny key/value backend so the store can be
chosen at compile time.

- New interface + conditional import (so the native build never pulls in `dart:js_interop`):

  ```
  shared/lib/src/auth/auth_key_value_store.dart        // abstract AuthKeyValueStore
  shared/lib/src/auth/auth_key_value_store_native.dart // FlutterSecureStorage impl
  shared/lib/src/auth/auth_key_value_store_web.dart    // package:web window.localStorage impl
  ```

  `auth_storage.dart` imports:

  ```dart
  import 'auth_key_value_store_native.dart'
      if (dart.library.js_interop) 'auth_key_value_store_web.dart';
  ```

  > **Correction to the Phase-2 sketch:** an unconditional `package:web` import with a runtime
  > `if (kIsWeb)` branch does **not** compile for native (`dart:js_interop` is web-only). The web
  > backend must sit behind a **conditional import** (`if (dart.library.js_interop)`); `kIsWeb` may
  > still be used inside the web implementation if useful, but it cannot be the only selector.

- `AuthStorage` keeps its public API (`saveTokens`, `getAccessToken`, `getRefreshToken`,
  `saveRememberedEmail`, `getRememberedEmail`, `clearTokens`, `saveAccessToken`,
  `saveRefreshToken`) and delegates to the injected/created store. Inject the store (or an optional
  `FlutterSecureStorage` for native) so tests can supply a fake; the current
  `AuthStorage({FlutterSecureStorage? storage})` ctor is only used by production providers —
  `shared/test` mock `AuthStorage` itself (`shared/test/auth/app_auth_controller_test.dart:6`), so a
  ctor change is low-risk.
- **Wrap every read/write in `try/catch`.** Reads return `null` on failure; writes swallow (best
  effort) so a failure leaves the in-memory token as the session of record. This is the safety net
  that makes Phase 1e sufficient even if the backend still throws.
- Add `web: ^1.1.1` to `shared/pubspec.yaml` dependencies (transitively present in
  `pubspec.lock:1279`; declare it directly for the conditional-import compile).

### Phase 3 — tests

Extend `shared/test/auth/app_auth_controller_test.dart` (existing mocktail harness, `:6-61`) with:

1. **Cold start, refresh only** — `getAccessToken → null`, `getRefreshToken → 'r'`; refresh POST
   returns fresh tokens; `/me` returns a user ⇒ `authenticated`, `saveTokens` called, **no**
   `clearTokens`.
2. **Cold start, access + `/me` 500** — `fetchMe` surfaces `ServerException` ⇒ tokens kept,
   `verifyNever(storage.clearTokens)`, no state crash.
3. **Cold start, access + network error** — a `DioException` with no response (timeout) ⇒ tokens
   kept.
4. **`/me` 401 → refresh once → retry** — first `/me` 401, refresh OK, retried `/me` returns a user
   ⇒ `authenticated`.
5. **Refresh transient failure keeps tokens** — refresh POST 500/connection error ⇒ `refreshToken()`
   is `false`, `verifyNever(dio.post(logoutEndpoint, ...))`, `verifyNever(storage.clearTokens)`.
6. **Refresh definitive 401 (and 400) clears locally** — refresh POST 401 ⇒ `refreshToken()` false,
   `clearTokens` called, **no** logout POST.
7. **Storage throw in `login`** — `saveTokens` throws ⇒ `login` still reaches `authenticated` (in
   memory), no exception escapes.
8. **Storage read throw in `checkAuth`/`refreshToken`** — `getAccessToken`/`getRefreshToken` throw ⇒
   treated as absent, no crash.

New `shared/test/auth/auth_storage_test.dart`:

9. **Backend round-trip** via an in-memory fake `AuthKeyValueStore` (write → read → delete across
   all keys).
10. **Failure swallowing** — a store whose read/write throws ⇒ `get*` returns `null` and `save*` /
    `clearTokens` complete without throwing.

Web-specific adapter: `window.localStorage` cannot be exercised by `melos run test` (VM). Mark the
web adapter's browser behavior **UNVERIFIABLE in the VM suite** and cover it with a fake of the
interface; a `flutter test --platform chrome` run (or a manual reload check) is the exact command to
close it.

Optional rider integration (if cheap): a splash test where `checkAuth` recovers from a refresh token
and routes to `/home` rather than `/login`
(`rider_app/test/features/auth/presentation/splash_screen_test.dart` — may need a new file).

### Phase 4 — dev workflow (optional, separate commit)

Pin a fixed web port in `scripts/dev-all.sh` (currently `DEVICE="chrome"` with no `--web-port`,
`:29`) and in docs, e.g. `flutter run -d chrome --web-port 5173`, so the browser origin — and thus
`localStorage` — is stable across dev-server restarts. This is a dev-ergonomics aid, not the fix.

## Invariants

- **No API / server change.** The fix is entirely Flutter. The access/refresh TTLs
  (`internal/config/config.go:195-196`) stay as they are.
- **One classification boundary.** `_isDefinitiveAuthFailure` is the only place that decides
  "dead session"; 403 stays with `onForbiddenProfile()` so the driver onboarding path
  (`app_auth_controller.dart:94-99`) is unchanged.
- **Transient never wipes.** No `clearTokens()` / `logout()` on a timeout, connection error, 5xx, or
  parse failure. A transient failure leaves storage and the in-memory token intact.
- **`logout()` keeps its meaning.** It is the user-initiated / switch-account revoke path and still
  POSTs `logoutEndpoint`; the new local-only clear must not replace it there.
- **Storage is best-effort.** Every `AuthStorage` read/write is `try/catch`ed; a storage failure
  degrades to an in-memory session — it is never a hard failure and never a forced re-login.
- **Re-export-shim rule.** `AuthStorage` stays public in `shared/`; the rider/driver shims
  (`rider_app/lib/core/auth/auth_storage.dart:1`,
  `driver_app/lib/core/auth/auth_storage.dart:1`) and the providers
  (`auth_provider.dart:14`) keep importing the same symbol. New store classes are internal to
  `shared/src/auth/`; do not mint app shims.
- **Web build stays clean.** The web backend is behind a conditional import
  (`if (dart.library.js_interop)`); no unconditional `dart:js_interop` / `package:web` import may
  enter code compiled for native.
- **Single-flight refresh.** Concurrent refresh callers (interceptor + `checkAuth`) coalesce; no two
  `/auth/refresh` rotations race.

## Out of scope

- **API contract / server work** — TTLs, refresh rotation semantics, `/auth/refresh` status codes.
  The concurrent `api_plans/[auth]_web_session_token_contract.md` owns any of that; this plan does
  not depend on it (see below).
- **Driver-specific auth wiring / tests** — the parallel
  `driver_app_plans/01_[auth]_web_session_persistence.md` owns those and references this plan for the
  shared core.
- **A web XSS / CSP hardening program**, token storage at rest, or moving to httpOnly cookies — the
  plan only swaps the persistence backend and makes failures non-fatal.
- **Splash retry UX** — whether a transient cold-start failure should auto-retry or offer a "Try
  again" is a product decision (see open decisions); this plan only stops it from clearing tokens.
- **Other shared `flutter_secure_storage` consumers** — there are none beyond `AuthStorage`.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

`melos run test` runs the shared package on the Dart VM. The browser `localStorage` adapter needs a
web-platform run to be truly verified; if it cannot be executed here, mark that specific claim
**UNVERIFIABLE** and record the exact command (`flutter test --platform chrome` from
`shared/`, or the manual reload check). Do not claim the web persistence is verified from a VM-only
run.

## Cross-domain notes

- **Shared core, two consumers.** Both `rider_app` and `driver_app` subclass `AppAuthController` and
  share `AuthStorage`, so Phases 1–2 fix both. The rider app gets the behavior for free. The
  parallel **`driver_app_plans/01_[auth]_web_session_persistence.md`** must **reference this plan for
  the shared core** and cover only driver-specific wiring/tests (driver `AuthNotifier` session
  behavior, driver splash, driver test additions) — it must not re-specify or fork the shared
  controller/store logic.
- **API: none required.** The concurrent `api_plans/[auth]_web_session_token_contract.md` may
  formalize refresh-token contract/TTL behavior. This plan is independent and does **not** list it in
  `depends_on`: the Flutter fix works against the current server. If that contract changes the
  status code a dead refresh returns (e.g. 400 → 401 or a new code), update
  `_isDefinitiveAuthFailure` — the classification is code-based, so it is a one-line coordination,
  not a dependency.
- **On landing, update `rider_app_plans/STATUS.md`:**
  - Add a one-line `### [auth]` Landed entry: "web session persistence: `checkAuth` recovers via the
    refresh token and only clears on definitive 401/400; `refreshToken` is single-flight and never
    server-revokes on a transient failure; web `AuthStorage` uses a conditional-import
    `localStorage` backend" with `file:line` evidence
    (`shared/lib/src/auth/app_auth_controller.dart`, `shared/lib/src/auth/auth_storage.dart`,
    `shared/lib/src/auth/auth_key_value_store_web.dart`) and the test file.
  - Remove this plan's row from Open plans and delete this file (git history is the archive).
  - Add a `### [auth]` driver note if the driver plan lands here too, or leave it to
    `driver-planner`.

## Open product decisions surfaced

1. **Cold-start refresh layer** — the `ApiClient` 401 interceptor already calls `refreshToken()`
   (`api_client.dart:47-72`). Recommendation: keep the explicit `checkAuth` refresh and make
   `refreshToken()` single-flight so the two coalesce. Confirm this over the alternative of relying
   solely on the interceptor (which leaves the "refresh-token-only" branch unimplemented).
2. **Transient-failure UX** — when a cold start fails transiently, the tokens survive but the user
   still sees `/login` this launch. Should the splash auto-retry once, or show a "Trying to
   reconnect…"/retry affordance? (This plan deliberately only stops the data loss.)
3. **Web storage choice** — `window.localStorage` (survives reload, XSS-readable) vs. keeping
   `flutter_secure_storage` web (WebCrypto + secure-context requirement). The bug report favors
   reliability; confirm localStorage is acceptable given it is not XSS-proof.
4. **Fixed dev web port** — pin `--web-port` in `dev-all.sh`/docs (Phase 4)? It stabilizes the
   origin for localStorage during development; a one-line consumer change if the team prefers the
   Flutter-chosen ephemeral port.

## Numbering / tag decision (recorded for the next auditor)

- **Unnumbered, `tag: auth`, `depends_on: []`.** The work is Flutter-only and has no *open-plan*
  prerequisite. The concurrent API contract plan is a coordination note, not a dependency, so it is
  **not** listed in `depends_on` and this file earns no `NN_` prefix (skill: `depends_on` non-empty
  ⟺ `NN_` prefix, read as an **open-plan** target). It is an independent plan under the
  `auth` tag (the sibling Enter-to-submit plan landed and was condensed into `STATUS.md` → Landed
  `[auth]`, 2026-10-08); independent chains under the same tag do not number.
