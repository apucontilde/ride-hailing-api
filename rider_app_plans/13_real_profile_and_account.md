# Plan: Real Rider Profile & Account (parity with the driver app)

**Status:** ☑ done — landed. `melos run analyze` clean in all three packages;
`melos run test` green (rider_app 143, driver_app 179, shared 35). See
[As built](#as-built) at the bottom for the two places the implementation
deviated from the plan text.

Follow-up to the sign-out work that landed `features/settings/presentation/settings_screen.dart`.
Logout is done; this plan covers the **remaining** places where the rider app is still
hardcoded or ignores shared logic the driver app already uses.

**Read first:** `rider_app/lib/core/auth/auth_provider.dart`, `rider_app/lib/features/home/presentation/profile_screen.dart`, `rider_app/lib/features/home/presentation/home_screen.dart` (drawer, ~L198-273), `rider_app/lib/core/api/endpoints.dart`, `shared/lib/src/models/auth_user.dart`, `shared/lib/src/auth/app_auth_controller.dart`, and the driver app's equivalents: `driver_app/lib/core/auth/auth_provider.dart`, `driver_app/lib/features/profile/providers/profile_notifier.dart`, `driver_app/lib/features/profile/presentation/profile_screen.dart`.

## Problem

Four gaps, in rough dependency order:

1. **`ProfileScreen` is 100% fake.** Every value is a literal: `CircleAvatar` with a generic
   person icon, `Text('Rider')`, `'rider@example.com'`, two `'Not set'` rows. Meanwhile
   `GET`/`PUT /rider/me` are **real** endpoints — the rider app just never calls them.
2. **`AuthNotifier.fetchMe()` throws away half the response.** It reads only `data['user']`
   and discards the `rider` sub-object (`first_name`, `last_name`, `photo_url`, `status`)
   that the same call already returned.
3. **No profile cache, and the auth hooks go unused.** The driver's `AuthNotifier` overrides
   `onAuthenticated` to seed `driverProfileProvider`; the rider overrides *nothing* and has
   no equivalent provider. So the drawer header can only hardcode `Text('Rider')`
   (`home_screen.dart:219`) instead of showing who is signed in.
4. **`AuthUser` (shared) is too thin for a profile UI** — no `firstName` / `lastName` /
   `photoUrl`.

Overlaps plan `06-auth-and-profile.md` AC-2, which is still unstarted. **This plan supersedes
the AC-2 section of `06`**; AC-1 (forgot-password) and AC-3 (401 refresh, already shipped in
`shared/lib/src/api/api_client.dart`) are unaffected. Where the two disagree, this plan is
right — see the response-shape warning below.

## Endpoint facts (all real — verify against `internal/` before coding)

```http
GET    /api/v1/rider/me          # → 200 {user:{id,email,phone,role,status}, rider:{first_name,last_name,photo_url,status,...}}
PUT    /api/v1/rider/me          # body {first_name,last_name,photo_url,phone} → 200 {rider}          (rider.go:65)
PUT    /api/v1/rider/me/status   # body {status}                             → 200 {rider}          (rider.go:98)
DELETE /api/v1/rider/me          # → 200 {message:"account deactivated"} — SOFT delete only       (rider.go:120)
```

All four sit behind `authMw` + `RequireRole("rider")` (`internal/router/router.go:116-119`).
`endpoints.dart` currently declares **none** of the write endpoints — only `riderMe` (GET).

⚠️ **`PUT /rider/me` returns only `{rider}`, not `{user, rider}`.** Plan `06` claims otherwise.
`phone` is written to the *user* row (`internal/handler/rider.go:79-83`) and is **not** echoed
back, so a phone edit cannot be confirmed from the response — re-read `GET /rider/me` (or merge
the submitted value locally) before showing "Profile saved". `photo_url` is likewise
overwritten unconditionally: omitting it from the body **clears** the stored photo
(`rider.go:76` assigns `body.PhotoURL` unconditionally), so the edit form must always send
the current value.

**Do NOT build UI for** `/rider/me/preferences`, `/rider/payment-methods`, `/rider/ratings`,
`/rider/favorites` — all four are `platformHandler.StubPayment` (`router.go:120-128`). That
rules out the rider's existing `PaymentScreen` and `SecurityScreen` placeholders; leave them as
stubs and keep the skip list in `07-sos-and-skip.md` authoritative.

## Solution

1. **`shared/lib/src/models/auth_user.dart`** — add `firstName`, `lastName`, `photoUrl`
   (nullable, defaulted) parsed from the `rider` sub-object, and a `fullName` getter.
   Add-only to `shared/`; keep every `rider_app/lib/core/**` and
   `features/auth/model/auth_user.dart` shim exactly as-is (see `AGENTS.md`).
2. **`rider_app/lib/core/api/endpoints.dart`** — add `riderMeStatus`. `riderMe` (GET) is
   reused for `PUT` and `DELETE`; see deviation 1 under [As built](#as-built).
3. **`rider_app/lib/core/auth/auth_provider.dart`** — add
   `final riderProfileProvider = StateProvider<RiderProfile?>((ref) => null);`; make
   `fetchMe()` parse **both** `user` and `rider` and seed the cache; override
   `onAuthenticated` to re-seed on login/token rotation. Mirror
   `driver_app/lib/core/auth/auth_provider.dart:18,39-56`.
4. **New `rider_app/lib/features/home/model/rider_profile.dart`** — `RiderProfile.fromJson`
   over the `rider` sub-object. (`shared/lib/src/models/ride.dart` covers rides, not profiles;
   the driver keeps its profile app-local, so do the same.)
5. **New `rider_app/lib/features/profile/providers/profile_notifier.dart`** —
   `ProfileState{profile, saving, error}` + `updateProfile({firstName,lastName,phone,photoUrl})`,
   ported from `driver_app/lib/features/profile/providers/profile_notifier.dart`. On success
   write through to `riderProfileProvider`, then re-read `GET /rider/me` so `phone` is
   authoritative (see the response-shape warning).
6. **`profile_screen.dart`** — replace every literal with real data; add the edit form
   (first/last name via `Validators.validateName`, phone via `Validators.validatePhone` —
   both already in `shared/` and currently unused by the rider app), an initials/`NetworkImage`
   header like the driver's `_ProfileHeader`, and keep the Settings tile added with the
   sign-out work. Wrap the body in a `ListView` (it is a `SingleChildScrollView` today).
7. **Drawer header** (`home_screen.dart:198-229`) — swap the hand-rolled `DrawerHeader` for
   the driver's `UserAccountsDrawerHeader`, fed from `riderProfileProvider`. Keep the
   `onTap → /profile` behaviour.

## Also fix: logout does not clear cached profile state

`shared/lib/src/auth/app_auth_controller.dart:210-226` — `logout()` resets `AuthState` and
clears tokens but has **no hook** for app-level caches. In the driver app
`driverProfileProvider` therefore survives a sign-out, so a stale profile (including
`status: online`) is still in the container for the next session. This is a live bug today and
becomes one for the rider the moment step 3 lands.

- Add `Future<void> onLoggedOut() async {}` to `AppAuthController` and `await` it at the end of
  `logout()`.
- Override it in **both** `AuthNotifier`s to reset their profile provider to `null`.
- Test: logout → the profile provider reads `null` (add to
  `rider_app/test/core/auth/auth_provider_test.dart` and the driver equivalent).

## Known wart, optional

`shared/lib/src/api/api_client.dart` excludes only `/auth/login` and `/auth/refresh` from the
401 auto-refresh path, so a 401 from `POST /auth/logout` re-enters
`unauthorizedHandler → refreshToken() → (on failure) logout()`. Harmless today because
`logout()` swallows every error and local cleanup always wins, but it is wasted work on a
dead session. Consider adding `/auth/logout` to `isAuthEndpoint` while touching this area.

## Tests

- `test/core/auth/auth_provider_test.dart` — `fetchMe` seeds `riderProfileProvider` from the
  `rider` sub-object; `onAuthenticated` re-seeds; **`logout()` clears it**.
- `test/features/profile/providers/profile_notifier_test.dart` — `updateProfile` sends the right
  body (including the preserved `photo_url`), surfaces a mapped error, writes through to
  `riderProfileProvider` on success.
- `test/features/home/presentation/profile_screen_test.dart` — renders API values (no
  `'rider@example.com'` literal), save button disabled while `saving`, error text shown.

## Verify

```bash
cd rider_app && flutter analyze && flutter test
cd shared    && flutter analyze && flutter test   # AuthUser change is shared
cd driver_app && flutter analyze && flutter test  # onLoggedOut override
```

## Acceptance

- [x] No hardcoded `'Rider'` / `'rider@example.com'` / `'Not set'` left in `profile_screen.dart`
  or the drawer header.
- [x] Name, photo and phone come from `GET /rider/me`; edits persist through `PUT /rider/me` and
  `photo_url` survives an edit that does not touch it.
- [x] Signing out clears the cached profile in **both** apps.
- [x] No new UI over a backend stub.

## As built

Deviations from the plan text, and the things a follow-up must not undo:

1. **`endpoints.dart` gained only `riderMeStatus`, not `updateRiderMe` / `deleteRiderMe`.**
   `GET`, `PUT` and `DELETE /rider/me` share one path, so the existing `riderMe`
   constant already addresses all three — declaring `updateRiderMe` alongside it would have
   been a duplicate constant pointing at the same string. This matches the driver's
   `driverMe`. The soft-delete (`DELETE`) is deliberately **not** wired to any UI: it
   deactivates the account with no undo, so it wants a confirm dialog and a plan of its own.
2. **`AuthUser.fromJson` takes an optional `rider:` argument** instead of sniffing a
   `rider` key out of the map it is handed. `GET /rider/me` answers `{user, rider}`, but
   `fetchMe` is given the `user` sub-object, so the sibling has to be passed explicitly;
   a hidden key lookup would silently depend on callers passing the whole envelope.
3. **`onAuthenticated` is guarded by a warm cache** (`if (riderProfileProvider != null)
   return`). The driver's version re-fetches unconditionally, which makes a cold start
   issue two `GET /rider/me` calls. One GET is enough here because `fetchMe` runs
   immediately before it and already seeds the cache — `riderProfileProvider` still
   starts `null` on login, which is the only path that needs the extra read.
4. **`ProfileNotifier` always sends `first_name` / `last_name` / `photo_url`**, falling back
   to the cached profile for anything the caller did not pass. `PUT /rider/me` assigns all
   three unconditionally (`internal/handler/rider.go:74-76`), so a partial body would wipe
   the omitted ones. `phone` is the exception and stays optional: the handler ignores an
   empty one (`rider.go:79`).
5. **`ProfileNotifier.updateProfile` re-reads `GET /rider/me` via a new
   `AuthNotifier.refreshProfile()`** (returns `Future<RiderProfile?>`, `null` on failure)
   rather than calling the endpoint itself. That keeps the `users` row reachable from one
   place and refreshes `AuthState.user` (email/phone) at the same time.
6. **No `'Rider'`-style fallback label anywhere.** The profile header and the drawer header
   both fall back to the rider's *email* when no name is set, and render nothing when there
   is neither — an invented role word would have been the same fake data this plan removes.
7. **The `Default Address` tile was dropped, not filled in.** There is no saved-places
   provider in the rider app and `/rider/favorites` is a `StubPayment` stub, so the row had
   no honest value to show.
8. **Widget tests use an empty `photo_url`.** `flutter_test` has no network, so a real
   `NetworkImage` fails the test asynchronously. The photo path is covered by
   `RiderProfile`'s unit test and by the notifier's `photo_url`-preservation assertions.
9. **The optional `isAuthEndpoint` wart was fixed** — `/auth/logout` is now excluded from
   the 401 auto-refresh window, with a test in `rider_app/test/core/api/api_client_test.dart`.

Tests added:

- `rider_app/test/features/home/model/rider_profile_test.dart` (new)
- `rider_app/test/features/profile/providers/profile_notifier_test.dart` (new)
- `rider_app/test/features/home/presentation/profile_screen_test.dart` (new)
- `rider_app/test/core/auth/auth_provider_test.dart` (+9)
- `rider_app/test/features/home/presentation/home_screen_test.dart` (+1 drawer header)
- `driver_app/test/core/auth/auth_provider_test.dart` (+1)
- `shared/test/ride_hailing_shared_test.dart` (+5 `AuthUser`)
