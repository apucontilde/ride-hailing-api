---
tag: profile
depends_on: []
status: open
---

# Profile tests + onboarding name persistence

> **Status: 🟠 OPEN — tests missing.** The profile / vehicle / settings screens and
> `ProfileNotifier.updateProfile` already landed and are recorded in `STATUS.md`
> → Landed `[profile]`. What remains is (a) the three test suites this plan
> originally required, which were never written, and (b) making the onboarding
> first/last name actually persist to the server. No behaviour change to the
> screens is in scope here.

Close the two open profile items: protect the already-shipped profile surface
with tests, and make onboarding persist the identity it collects.

## Facts (re-audited)

- **Profile:**
  - `GET /driver/me` → `{"driver":{"user_id","first_name","last_name","photo_url",
    "status","onboarding_status","rating_summary","created_at","updated_at"}}`
    (flat — **no nested `user`**, matching the bootstrap's `DriverProfile`).
  - `PUT /driver/me` accepts `{first_name, last_name, phone}` (whichever subset)
    and returns the updated driver (`internal/handler/driver.go:88-104`).
  - `ProfileNotifier.updateProfile` sends only provided fields, replaces the
    cached profile with the response, and preserves the previous value on failure
    — `driver_app/lib/features/profile/providers/profile_notifier.dart:56`.
- **Onboarding gap (US-D1 🟡):** `onboarding_screen.dart` collects
  `_firstNameController` / `_lastNameController` but performs no `PUT /driver/me`
  after `POST /driver/register`, so a freshly onboarded driver lands on `/home`
  with an empty name — `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart:44`.
- **Stubs (feature-gated, from `internal/handler/platform.go`):**
  `GET/PUT /driver/me/vehicle`, `GET/POST /driver/me/documents`. Rule: gate, don't
  fake; the vehicle screen renders "coming soon" while the flag is off
  (`driver_app/lib/features/vehicle/presentation/vehicle_screen.dart`).

## Work

1. `driver_app/lib/features/onboarding/presentation/onboarding_screen.dart`:
   after a successful `POST /driver/register` (and token rotation), call
   `ProfileNotifier.updateProfile(firstName:, lastName:)` (or `PUT /driver/me`
   directly) so the collected names persist before the driver reaches `/home`.
   Handle failure non-fatally (the driver still lands on `/home`; the profile edit
   form can retry) and drop the stale comments that document the gap.

## Tests (the three suites this plan requires)

- `driver_app/test/features/profile/providers/profile_notifier_test.dart`:
  update sends only provided fields; response replaces cache; failure preserves
  old profile + surfaces error.
- `driver_app/test/features/profile/presentation/profile_screen_test.dart`:
  renders rating summary; edit save calls `updateProfile`; gated vehicle tile
  shows "coming soon" when the flag is `false`.
- `driver_app/test/features/settings/presentation/settings_screen_test.dart`:
  sign-out confirm → tokens cleared → router falls back to `/login`.
- `driver_app/test/features/onboarding/...` (add): onboarding posts the names via
  `PUT /driver/me` after registration.

## Acceptance

- The shipped profile/vehicle/settings surface is covered by the three suites.
- A freshly onboarded driver's name is present on the server (and reflected in
  `GET /driver/me`) without a manual profile edit.
- Vehicle/documents stay visibly "coming soon" (flag) — never silently fake-saved.

## Verification

```bash
make flutter-analyze
make flutter-test
```
Live: register a new driver → onboarding names → refresh → profile shows the name.
