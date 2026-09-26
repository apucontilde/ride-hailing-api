# Plan 06 — Profile / vehicle & documents (feature-gated) / settings (US-D3)

> **Status: 🟠 CODE LANDED, NO TESTS** (re-audited 2026-09-25). All the screens
> exist — `ProfileNotifier.updateProfile` (PATCH-style partial fields, replaces
> the cached profile, preserves the previous value on failure), the profile screen
> (avatar, editable first/last name, vehicle + document chips, ★ rating summary,
> validated form), the feature-gated vehicle screen (fetches
> `GET /driver/me/vehicle` behind `ApiConfig.vehicleFeatureEnabled`, which is a
> backend STUB so it is gated, not faked), and settings (sign-out + version +
> server URL). **The plan's three test suites were never written** — the whole
> surface is unprotected. Also still open: onboarding collects first/last name and
> never `PUT`s it (US-D1 🟡), and the history entry point links to a placeholder.

Finish the personal profile surface: read + update `GET/PUT /driver/me`, show the
rating summary, and add vehicle + documents **as feature-gated placeholders**
because those endpoints are backend STUBs. Settings keeps sign-out/version. This
plan has no dependencies on 01–05.

## Facts (re-audited)

- **Profile:**
  - `GET /driver/me` → `{"driver":{"user_id","first_name","last_name","photo_url",
    "status","onboarding_status","rating_summary","created_at","updated_at"}}`
    (flat — **no nested `user`**, matching the bootstrap's `DriverProfile`).
  - `PUT /driver/me` accepts `{first_name, last_name, phone}` (whichever subset)
    and returns the updated driver (`internal/handler/driver.go:79-93`).
  - There is **no avatar-upload endpoint** — `photo_url` is a URL string field;
    the "photo" action should reuse the existing `photo_url` value (rider-app
    pattern) or be omitted until an upload endpoint exists.
  - `rating_summary` = `{average, count}` → show "★ 4.8 (12 ratings)".
- **Stubs (feature-gated, from `internal/handler/platform.go`):**
  `GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents`. Response is a
  hardcoded shape, writes do nothing persistent. **Rule: gate, don't fake.** A
  `features/vehicle` flag in `lib/core/...` marks when the backend is real; until
  then the vehicle/documents screens render a "Coming soon — vehicle & documents
  verification" empty state rather than pretending to save.
- **Settings:** sign-out (`POST /auth/logout` inherited from bootstrap, clears
  tokens → router drops to `/login`), app version, server base URL display,
  "rate the app" stub link withheld (no store URL yet).

## Work

1. `lib/features/profile/providers/profile_notifier.dart` (new):
   - Reads `GET /driver/me` from the authenticated session (the bootstrap already
     cached it; expose it as a `FutureProvider` refreshable on demand).
   - `updateProfile({firstName?, lastName?, phone?})` → `PUT /driver/me` → replace
     cache with the response; `ChangingName`/saving state for the form.
   - `rating_summary` convenience getter.
2. `lib/features/profile/presentation/profile_screen.dart` (rework placeholder):
   - Header: avatar (from `photo_url` or initials), name, `onboarding_status` chip,
     rating summary, `status` dot.
   - Edit form (first/last name, phone) with save → `updateProfile`, inline
     errors, disabled while in flight.
   - Tiles → `rides_history_screen` (plan 05) + `settings_screen`.
   - Vehicle tile → gated screen below.
3. `lib/features/vehicle/presentation/vehicle_screen.dart` (new, gated):
   - Reads `vehicleFeatureEnabled` flag (a const `bool` in
     `lib/core/config.dart` next to `ApiConfig`). `false` → friendly "coming soon"
     empty state with the note that verification is handled by admin; `true` →
     exercise `GET/PUT /driver/me/vehicle` (add to `endpoints.dart`) with the
     shape documented there.
4. `lib/features/settings/presentation/settings_screen.dart` (extend placeholder):
   - Sign-out (clear-token path already exists) — confirm dialog.
   - App version (`package_info_plus` or hardcoded `1.0.0` to avoid a new dep;
     prefer adding `package_info_plus ^8.1.1` to pubspec if trivial).
   - About line with `API_BASE_URL`.
5. `lib/features/onboarding/presentation/onboarding_screen.dart`: follow-up call —
   confirm the saved identity actually reaches the profile by the time the driver
   lands on `/home` (bootstrap already registers + rotates; this plan just wires
   the profile screen to reflect it live).

## Tests

- `test/features/profile/providers/profile_notifier_test.dart`:
  update sends only provided fields; response replaces cache; failure preserves
  old profile + surfaces error.
- `test/features/profile/presentation/profile_screen_test.dart`:
  renders rating summary; edit save calls `updateProfile`; gated vehicle tile
  shows "coming soon" when flag `false`.
- `test/features/settings/presentation/settings_screen_test.dart`:
  sign-out confirm → tokens cleared → router falls back to `/login`.

## Acceptance

- Profile shows live server data and persists edits back to the server.
- Vehicle/documents are visibly "coming soon" (flag) — never silently fake-saved.
- Sign-out cleanly returns to auth gate (existing bootstrap flow untouched).

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: edit first/last name → refresh app → name persists; toggle flag in
`config.dart` to verify the gated vehicle screen renders either way.