---
tag: auth
depends_on: []
status: open
---

# [auth] Enter-to-submit on web/desktop only (rider login)

> Independent plan. App-local only — no API change, no `shared/` change, no driver-app change.
> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test`.

## Goal

On **web and desktop**, pressing Enter in the rider login form submits (logs in). On **mobile**
(iOS/Android) it must **not** submit: mobile keeps the button as the submit affordance and does not
accidentally log in while filling fields. The behavior reuses the existing `_submit()` path and its
validation/loading guards — there is no second login path.

## Current state (verified)

### Login screen today

`rider_app/lib/features/auth/presentation/login_screen.dart`

- Form state: `GlobalKey<FormState> _formKey` `:16`; `_emailController` / `_passwordController`
  `:17-18`; `_obscurePassword` `:19`; `_rememberMe` `:20`.
- The single submit handler `_submit()` `:45-88`; it validates first `:46`
  (`if (!_formKey.currentState!.validate()) return;`), then calls
  `notifier.switchAccount(...)` `:72` or `notifier.login(...)` `:74`, then navigates on
  `authState.isAuthenticated` `:85-87`.
- The email field is an `AuthTextField` `:105-113` and the password field `:115-130`. **Neither
  passes `textInputAction` or `onFieldSubmitted`.**
- The button is the only submit entry point: `ElevatedButton` `:151-160`,
  `onPressed: authState.isLoading ? null : _submit` `:152` (spinner while loading `:153-158`).
- `AuthState.isLoading` is `status == AuthStatus.loading` — `shared/lib/src/auth/app_auth_controller.dart:36`
  (`AuthStatus` enum `:10`). `_submit()` itself does **not** check `isLoading`; the button's `onPressed`
  is the only in-flight guard.

### The field widget today

`rider_app/lib/features/auth/presentation/widgets/auth_text_field.dart` — a plain `TextFormField`
`:29-41` with `controller`/`validator`/`obscureText`/`keyboardType`/`autofillHints`/`decoration` only.
**No `textInputAction`, no `onFieldSubmitted`, no `onEditingComplete`.** Its ctor is `:14-25`.

Confirmed no source-level keyboard-submit wiring anywhere (`rider_app/lib`, `driver_app/lib`,
`shared/lib` contain zero `textInputAction` / `onFieldSubmitted` / `onEditingComplete`; the only
hits are compiled build artifacts under `build/`).

### Platform detection today

- **There is no general platform helper in `shared/`** (no `kIsWeb` /
  `defaultTargetPlatform` / `dart:io Platform` in `shared/lib`).
- The only platform discriminator in the rider app is push-specific:
  `rider_app/lib/core/push/push_token_source.dart:24-34` — `currentDevicePlatform()` returns
  `DevicePlatform.web` when `kIsWeb` (`:25`), otherwise switches on `defaultTargetPlatform`
  (`:26-33`), folding **desktop into `android`** (`:31-32`, intentional for the push wire value).
  It is **not** reusable for a web/desktop/mobile decision.
- `driver_app/lib/core/push/push_token_source.dart:24-34` duplicates the same function — the
  repo's existing convention is an **app-local** platform helper per app, not a shared one.
- The rider `AuthTextField` is also duplicated in the driver app
  (`driver_app/lib/features/auth/presentation/widgets/auth_text_field.dart:3`); the login UI is
  **not shared**.
- No test currently uses `debugDefaultTargetPlatformOverride` (grep over `rider_app/test`,
  `driver_app/test`, `shared/test` is empty).

### Where the rider `AuthTextField` is used

`login_screen.dart:105,115`, `register_screen.dart:58,67,76`, and
`forgot_password_screen.dart:109`. Only the **login** screen is in scope; the widget change must be
purely additive so register/forgot are untouched.

## Scope

### 1. Pure, testable platform predicate (new app-local file)

New `rider_app/lib/core/platform/enter_to_submit.dart`:

```dart
import 'package:flutter/foundation.dart';

/// True when pressing Enter in a single-line form field should submit the
/// form. Web and desktop are keyboard-first; mobile alone must not submit
/// from the Enter key, so it keeps the button as its submit affordance.
bool shouldSubmitOnEnter({
  required bool isWeb,
  required TargetPlatform platform,
}) {
  if (isWeb) return true;
  switch (platform) {
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.fuchsia:
      return false;
  }
}
```

- `kIsWeb` cannot be flipped in a widget test, so the **pure function is the unit-testable source of
  truth** for the web branch; the widget reads the real `kIsWeb` / `defaultTargetPlatform` values.
- App-local (mirrors `core/push/push_token_source.dart`'s app-local platform helper convention);
  do **not** add it to `shared/`.
- No `dart:io` / `Platform.is*` anywhere — that would break the web build.

### 2. `AuthTextField` — additive keyboard props

In `rider_app/lib/features/auth/presentation/widgets/auth_text_field.dart` add optional
constructor params and forward them to the `TextFormField`:

- `final TextInputAction? textInputAction;`
- `final ValueChanged<String>? onFieldSubmitted;`

Defaults stay `null`, so the three existing call sites (register/forgot/login) compile and behave
unchanged until the login screen opts in. This is the minimal seam; do not change any other prop.

### 3. Login screen wiring (the only behavior change)

In `rider_app/lib/features/auth/presentation/login_screen.dart`:

- In `build`, compute once:
  `final enterSubmits = shouldSubmitOnEnter(isWeb: kIsWeb, platform: defaultTargetPlatform);`
  (imports: `package:flutter/foundation.dart`; `TextInputAction` comes from the material import
  already present).
- **Email field** (`:105-113`): `textInputAction: enterSubmits ? TextInputAction.next : null`.
  On web/desktop Enter moves focus to the password field (Flutter's built-in `next` focus advance);
  it does **not** submit. On mobile the value stays `null` → mobile keyboard behavior is unchanged.
- **Password field** (`:115-130`):
  - `textInputAction: enterSubmits ? TextInputAction.done : null`
  - `onFieldSubmitted: enterSubmits ? (_) => _submit() : null`
  So only the **last** field can submit, and only on web/desktop. Mobile passes `null` for both →
  the mobile widget tree is byte-for-byte the current one.
- Reuse `_submit()` unchanged as the handler — no `_submitOnEnter`, no parallel login path.

### 4. Double-submit guard in `_submit` (one path)

`_submit()` currently relies on the button being disabled (`:152`) and has no internal guard, so the
new Enter path could fire a second request while the first is in flight. Add a self-guard shared by
both callers:

- Add a private `bool _isSubmitting = false;`.
- At the top of `_submit()`, after the existing `validate()` line, or wrapping it:
  `if (_isSubmitting || ref.read(authProvider).isLoading) return;` then set `_isSubmitting = true`
  and clear it in a `finally`. This also closes the window where the account-switch dialog
  (`:54-70`) is open before `isLoading` becomes true.
- Keep the button's `onPressed: authState.isLoading ? null : _submit` exactly as is.

## Invariants

- **One submit path.** Enter invokes the same `_submit()` as the button; no second auth call, no
  duplicated validation/navigation.
- **No mobile behavior change.** On `TargetPlatform.android` / `iOS` (and non-web), the two fields
  keep `textInputAction: null` and `onFieldSubmitted: null`, exactly as today; the keyboard's
  action never logs in.
- **Web-safe.** The predicate uses only `package:flutter/foundation.dart` (`kIsWeb`,
  `defaultTargetPlatform`). No `dart:io` import may be introduced (it breaks the web build).
- **Respect loading + validation.** `_submit` still validates first and returns during an in-flight
  request, so Enter cannot double-submit or bypass validation.
- **Accessibility.** On desktop/web, keyboard submit is expected behavior and is now supported;
  the button remains the accessible labeled submit control on every platform.
- **Additive widget change only.** `AuthTextField`'s new params default to `null`; register
  (`register_screen.dart:58,67,76`) and forgot-password (`forgot_password_screen.dart:109`) are
  unchanged.
- **Re-export-shim rule.** The helper is app-local; nothing is added to `shared/` and no shim is
  minted.

## Out of scope

- **Driver app login** — separate `AuthTextField`
  (`driver_app/lib/features/auth/presentation/widgets/auth_text_field.dart:3`) and login screen; not
  shared, not changed.
- **Register screen** (`register_screen.dart`) and **forgot-password** / **reset-password** flows —
  they share `AuthTextField` but are not wired for Enter in this plan (the widget change keeps them
  compiling unchanged). A follow-up could opt them in the same way.
- **Global keyboard shortcuts / `Shortcuts`/`Actions`** — only in-field Enter on the password field.
- **Changing the mobile keyboard action** (e.g. adding `next`/`go` on mobile) — deliberately left
  as-is to preserve current mobile behavior; **locked 2026-10-08: mobile `textInputAction` stays
  `null`**.
- Any API, `shared/`, routing, or driver-app change; no `pubspec` change.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + native Melos 8
melos run analyze
melos run test
```

Add tests (mirror the existing mocktail + `http_mock_adapter` suites):

1. **Pure predicate** — new `rider_app/test/core/platform/enter_to_submit_test.dart`:
   - `isWeb: true` → `true` for every platform (web wins).
   - `isWeb: false` + `TargetPlatform.windows` / `linux` / `macOS` → `true`.
   - `isWeb: false` + `TargetPlatform.android` / `iOS` → `false`.
   (This is the only place the **web** branch can be exercised: `kIsWeb` is a const and cannot be
   overridden in tests.)
2. **Desktop Enter submits** — `rider_app/test/features/auth/presentation/login_screen_test.dart`:
   set `debugDefaultTargetPlatformOverride = TargetPlatform.linux` before pumping (reset to `null`
   in `tearDown`), fill both fields, focus the password
   (`await tester.tap(find.byType(TextFormField).at(1))`), then
   `await tester.testTextInput.receiveAction(TextInputAction.done)` and `pumpAndSettle`; assert the
   login `POST` fired exactly once (e.g. `verify(() => mockDio.post(any(), data: any(named: 'data')))
   .called(1)`).
3. **Mobile Enter does NOT submit** — same, with
   `debugDefaultTargetPlatformOverride = TargetPlatform.android`: send the same `done` action and
   assert `verifyNever(() => mockDio.post(any(), data: any(named: 'data')))` and that the screen is
   still on `/login`.
4. **No double-submit while in flight** — desktop override; stub `mockDio.post` with a `Completer`,
   focus password, fire `receiveAction(done)` twice (two `pump`s), assert `called(1)`.
5. **Button path unchanged** — existing tests (`renders email and password fields`, `shows
   validation errors for empty fields`, `shows error on failed login`, `shows loading state while
   logging in`, account-switch tests) must stay green; the empty-field test also proves Enter is
   validated through the normal path when a submit occurs on desktop.

## Cross-domain notes

- **API: none.** No endpoint, request, or contract change.
- **Shared: none.** The predicate and widget live in `rider_app`; `shared/` is untouched. If the
  driver app later wants the same behavior, it should add its own app-local helper (matching the
  existing duplicated `currentDevicePlatform` convention) rather than a shared symbol.
- **Driver: none.** Driver login is a separate copy; do not plan driver changes here.
- **STATUS rows to update on landing:**
  - Add a one-line `### [auth]` Landed entry: Enter submits on web/desktop only, via the shared
    `_submit()` path, with `file:line` evidence (login screen fields + new predicate) and the test
    file.
  - Remove this plan's row from Open plans and delete this file (git history is the archive).
  - No new known-bug row is required (this is a feature, not a fix). If landed while mobile
    regresses, record it as a known bug instead.

## Locked product decisions (2026-10-08 — product owner)

1. **Enter in earlier fields** — on web/desktop the email field uses `TextInputAction.next` so
   Enter advances to the password field; it does **not** submit the half-filled form.
2. **Mobile keyboard action** — mobile keeps `textInputAction: null`, exactly as today (no mobile
   behavior change).
3. **Which field submits** — only the password / last field submits (`TextInputAction.done` +
   `onFieldSubmitted`).
