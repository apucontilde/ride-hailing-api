---
tag: session
depends_on: ["rider_app_plans/[session]_switch_account.md"]
status: open
---

# Driver adoption: switch-account / cancel-session

> **Driver half of the shared `session` chain.** The shared `AppAuthController` semantics
> ("never silently overwrite an authenticated session; cancel the current session first when
> the credentials differ") are **owned by the rider plan** `rider_app_plans/[session]_switch_account.md`
> (head, unnumbered). That head already names this driver login screen as in-scope but
> explicitly owns the `shared/` engine. This plan is the **thin driver-side adoption**: wire the
> driver login screen to whatever guarded-switch predicate/flow the head lands, plus any
> driver-only wiring. Do **not** duplicate the shared-controller design here.

## Read first (repo-relative)

- `shared/lib/src/auth/app_auth_controller.dart` (`login` at 126-161 — unguarded; `logout`)
- `driver_app/lib/features/auth/presentation/login_screen.dart` (delegates at :51)
- `internal/service/auth.go` (`Login` 72-96 mints a fresh refresh token, never revokes a prior
  session; `Logout` 134-142 revokes a single token by exact refresh string)

## Facts (verified)

- `driver_app/lib/features/auth/presentation/login_screen.dart:51` calls
  `ref.read(authProvider.notifier).login(email, password)` with no pre-flight. The shared
  `login()` overwrites `access_token`/`refresh_token`/`AuthState` even while already
  authenticated (`app_auth_controller.dart:126-161`).
- Backend: every login mints a brand-new refresh token (`auth.go:86`) and never checks/revokes a
  prior `refresh_tokens` row; logout revokes only the one token (`auth.go:134-142`). No
  device/session primitive exists.

## Work (driver-only; the shared semantics live in the rider head)

1. Adopt the head's guarded-login surface on the driver login screen. Expected shape (final
   names come from the head): if the shared controller exposes a `needsAccountSwitch(…)`
   predicate / `switchAccount(…)` path, call it from `_submit()` before delegating to `login`.
2. Surface the same "Sign out of <current> and sign in as <new>?" confirmation the rider flow
   uses — matching UI, no bespoke guard logic duplicating the shared controller.
3. Add/extend `driver_app/test/features/auth/presentation/login_screen_test.dart` to cover the
   switch path (e.g. logged-in → login-as-other shows confirmation; confirming cancels the prior
   session before the new login) — reusing the mock `authProvider` pattern already in
   `driver_app/test/`.

## Out of scope

- The shared controller change itself, the backend session/device semantics
  (`device_id`/one-active-session), and the rider screen — all live in the rider head +
  api-planner. Note only, do not implement here.

## Acceptance

- Driver login never silently clobbers an existing authenticated session; switching accounts
  revokes the prior refresh token then logs in cleanly.
- The driver screen shares (not reimplements) the rider head's switch-account confirmation.

## Verify

```bash
export PATH=~/fvm/default/bin:$PATH
melos run analyze
melos run test
```