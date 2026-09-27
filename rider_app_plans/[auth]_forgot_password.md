---
tag: auth
depends_on: []
status: open
---

# Real forgot-password

**Partial** — the other two account hooks from the original plan are already landed or superseded:
AC-2 (real profile) landed and was superseded by the real-profile work, and AC-3 (401 auto-refresh)
landed in the shared `ApiClient`. See [STATUS.md](STATUS.md) Landed → `[auth]`. What remains is
AC-1 below.

**Read first:** `rider_app/lib/features/auth/presentation/forgot_password_screen.dart`,
`rider_app/lib/core/api/endpoints.dart`, `rider_app/lib/core/auth/auth_provider.dart`.

## AC-1 — real forgot-password

```http
POST /api/v1/auth/forgot-password   # body {email} → 200 (real: creates a DB reset token; message says to check email)
```

`ApiEndpoints.forgotPassword` exists (`core/api/endpoints.dart:5`) but is never called — the
screen only flips a local `_submitted` flag (`forgot_password_screen.dart:26-29`).

1. In `forgot_password_screen.dart`: replace the fake "check your email" branch with a call to
   `authProvider.forgotPassword(email)` (add the method if missing).
2. Show success state driven by the response; show `mapStatusCodeToException` message on failure.
   Keep the on-screen demo copy about checking email.

Test: `forgot_password_screen_test.dart` (mock adapter asserts POST body + success/error states).

## Verify

```bash
make flutter-analyze
make flutter-test
```

## Acceptance

- Forgot-password posts the real endpoint (no fake-only UI).
