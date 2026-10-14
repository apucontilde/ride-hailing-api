---
tag: auth
depends_on: ["landed [design] shared AppTextField adoption + [auth]/[session] login (driver_app_plans/STATUS.md)"]
status: open
---

# [auth] Enter/Return submits the auth forms

> Owner: `driver-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> STATUS.md Verification). The actual web-browser Enter key is **UNVERIFIABLE in this WSL tree**;
> the widget-level `receiveAction` test is the proxy (steps under Verification).

## Goal

Pressing Enter/Return in a driver auth form field must submit the form, on web and everywhere else.
Login is the acceptance target; the register/forgot/reset forms carry the identical defect and are in
scope.

## Current state (verified)

- `AppTextField` already exposes `textInputAction` and `onFieldSubmitted`
  (`shared/lib/src/components/app_text_field.dart:21-22,34-35,44-45`) — **no `shared/` change
  needed**.
- `driver_app/lib/features/auth/presentation/login_screen.dart`: email field `:104-112` and password
  field `:114-129` pass neither `textInputAction` nor `onFieldSubmitted`; `_submit()` is `:44-87`; the
  button is `onPressed: _submit` `:152`.
- Same defect, same widget: `register_screen.dart:61-93` (email/phone/password),
  `forgot_password_screen.dart:74-81` (email), `reset_password_screen.dart:79-95` (token/password).

## Scope (app-only)

- `login_screen.dart`: email → `textInputAction: TextInputAction.next`; password →
  `textInputAction: TextInputAction.done`, `onFieldSubmitted: (_) => _submit()`.
- `register_screen.dart`: email/phone → `next`; password → `done` + submit.
- `forgot_password_screen.dart`: email → `done` + submit.
- `reset_password_screen.dart`: token → `next`; password → `done` + submit.
- Double-submit guard: `onFieldSubmitted` fires regardless of the button's disabled state, so each
  `_submit` must no-op while loading (login/register read `ref.read(authProvider).isLoading`;
  forgot/reset already track `_isLoading`). Do not rely on the button alone.

## Tests to add/change

- `driver_app/test/features/auth/presentation/login_screen_test.dart`: after entering valid
  credentials, `await tester.testTextInput.receiveAction(TextInputAction.done)` on the password field;
  assert `POST /auth/login` was made and the router reached `/home`. Also assert the email field's
  `textInputAction == TextInputAction.next` and the password's `== TextInputAction.done`.
- Add a minimal `forgot_password_screen_test.dart` (single field, highest value) exercising
  `receiveAction(done)` → `POST /auth/forgot-password`. Register/reset get the same treatment if their
  suites are added; they currently have no test file.
- Assert a submit while loading is ignored (no second POST) in at least the login suite.

## Cross-domain

- None. `AppTextField` already supports the needed parameters; do not modify `shared/`.

## Open inputs

- Exact submit semantics on web: `TextInputAction.done` + `onFieldSubmitted` is the standard Flutter
  web path; if a browser quirk is found, the fallback is a `KeyboardListener`/`Focus.onKeyEvent` for
  `LogicalKeyboardKey.enter`. Resolve during the on-host web check.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH
melos run analyze
melos run test
```

On a web host: `flutter run -d chrome` (Windows SDK, UNC-mapped per AGENTS.md), focus each field, press
Enter, and confirm the form submits. **UNVERIFIABLE in this WSL tree.**
