# 06 — AC-1 forgot-password + AC-2 real profile + AC-3 401 auto-refresh

Account/auth hooks: make the fake screens real and keep sessions alive.

**Read first:** `rider_app/lib/features/auth/presentation/forgot_password_screen.dart`, `rider_app/lib/features/auth/model/auth_user.dart`, `rider_app/lib/features/home/presentation/profile_screen.dart`, `rider_app/lib/core/api/api_client.dart`, `rider_app/lib/core/auth/auth_provider.dart`. (Post-refactor: `ApiClient`, `AuthStorage`, `AuthUser`, and the token lifecycle now come from `shared/`; `rider_app/lib/core/auth/auth_provider.dart` subclasses `AppAuthController` and wires `ApiConfig.baseUrl`.)

## AC-1 — real forgot-password

```http
POST /api/v1/auth/forgot-password   # body {email} → 200 (real: creates a DB reset token; message says to check email)
```
1. In `forgot_password_screen.dart`: replace the fake "check your email" branch with a call to `authProvider.forgotPassword(email)` (add method if missing).
2. Show success state driven by the response; show `mapStatusCodeToException` message on failure. Keep the on-screen demo copy about checking email.

Test: `forgot_password_screen_test.dart` (mock adapter asserts POST body + success/error states).

## AC-2 — real profile

> **☑ DONE — and superseded by `13_real_profile_and_account.md`. Do not implement this
> section.** It was written before the rider/driver endpoint shapes were audited and is
> wrong in two places: `PUT /rider/me` answers `{rider}` only, never `{user, rider}`, and
> `photo_url` is assigned unconditionally, so an edit form that omits it clears the stored
> photo. Plan `13` is the one that landed, with the corrected facts.

```http
GET /api/v1/rider/me            # → 200 {user:{email,phone,...}, rider:{first_name,last_name,photo_url,status}}
PUT /api/v1/rider/me            # body {first_name, last_name, photo_url, phone} → 200 {user, rider}
PUT /api/v1/rider/me/status     # body {status} → 200   (optional availability toggle)
```
1. `auth_user.dart`: add `firstName`, `lastName`, `photoUrl`, `status` fields (from `rider` + `user`).
2. New `features/home/data/profile_provider.dart`: `fetchProfile()` (`GET /rider/me`), `updateProfile()` (`PUT /rider/me`).
3. `profile_screen.dart`: render real name/email/phone/photo from the API; add an edit form (first/last name, phone) that calls `updateProfile`; remove hardcoded "Rider" / "rider@example.com". Optional: `PUT /rider/me/status` toggle if the screen exposes availability.

## AC-3 — 401 auto-refresh (single-flight)

`api_client.dart` already has `_createErrorInterceptor` (maps errors) and an `onRequest` auth header. `AuthProvider.refreshToken()` (`auth_provider.dart:138`) exists but nothing calls it.

1. Add a Dio `Interceptor` **before** the error mapper: on `DioError` with `response?.statusCode == 401`:
   - If the failed request is itself `POST /auth/refresh` → don't retry; propagate (session dead).
   - Else: single-flight guard (a pending future shared across concurrent 401s) → call `authProvider.refreshToken()`; on success `setToken(newAccess)` + `handler.resolve(await dio.fetch(requestOptions))` once; on failure → force logout + rethrow.
2. Keep `_createErrorInterceptor` ordering: auth-retry first, error-mapping last (so thrown exceptions still map).
3. `AuthProvider.refreshToken()` must clear tokens on refresh failure (currently it returns bool — check/reset and expose).

Test: `api_client_test.dart` — 401 → refresh called → original request retried with new bearer (mock adapter: first call 401, second 200; assert only one refresh, concurrent 401s collapse to one refresh).

## Verify

```bash
cd rider_app && flutter analyze && flutter test
```

## Acceptance

- Forgot-password posts the real endpoint (no fake-only UI).
- Profile shows backend data; edit persists via `PUT /rider/me`.
- A session whose token expires mid-use transparently refreshes once; expired refresh token logs out.