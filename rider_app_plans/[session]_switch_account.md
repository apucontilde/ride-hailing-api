---
tag: session
depends_on: []
status: open
---

# Switch account — cancel current session + new login

There is **no error today**; this plan describes the missing "cancel current session and switch
account" behavior behind review note "login from an already-logged-in account gives error —
implement cancel session and new login."

**Read first** (all paths repo-relative):

- `shared/lib/src/auth/app_auth_controller.dart` (`login`, `logout`, token storage)
- `internal/service/auth.go` (`Login`, `RefreshAccessToken`, `Logout`, `generateTokenPair`)
- `internal/database/migrations/003_create_auth_tokens.up.sql` (refresh-token table)
- rider login screen `rider_app/lib/features/auth/presentation/login_screen.dart`
- driver login screen `driver_app/lib/features/auth/presentation/login_screen.dart` (driver app is
  the **driver-planner's** domain — note both screens, but the rider owns the shared/ semantics)

## Reality (verified)

- Shared `login()` has **no authenticated guard** — while authenticated it silently overwrites
  `access_token`/`refresh_token`/`AuthState` with the new account's values
  (`app_auth_controller.dart:126-161`).
- Backend mints a brand-new refresh token on every login and never checks/revokes any prior
  session (`internal/service/auth.go:72-96`). `refresh_tokens`
  (`003_create_auth_tokens.up.sql:1-8`) has no one-active-session uniqueness constraint.
- Logout revokes a single token (`auth.go:134-142`) — it needs the exact refresh string; there is
  no device/session concept and no "revoke-all-for-user" primitive.

## Client-side flow (shared/ + both screens)

1. `AppAuthController`: add a `switchAccount` / guarded-login path so that when `status ==
   authenticated` and credentials differ, the app asks to **cancel the current session** first
   (revoke the current refresh token) before minting the new one — no silent overwrite.
2. Decide the guard's shape: expose a `needsAccountSwitch` predicate (compare current
   `AuthUser` email/id vs. attempted login), and a `cancelCurrentSession()` that calls the
   logout/revoke endpoint with the stored refresh token before proceeding.
3. Both login screens surface the confirmation ("Sign out of <current> and sign in as <new>?")
   instead of throwing or clobbering state.

## Backend session/device semantics (owned by api-planner — note, do NOT implement here)

- Optional long-term: add a `device_id`/`session_id` column to `refresh_tokens`, and on login
  revoke prior active refresh tokens for the same user+device (or add a
  one-active-session-per-user uniqueness constraint). `Logout` should support
  revoke-by-device/session, not only single-token.

## Acceptance

- Switching accounts revokes the prior session (no orphaned refresh token) and logs in cleanly.
- `login()` never silently overwrites an existing authenticated state.
- rider + driver login screens share the switch-account confirmation.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```