---
tag: profile
depends_on: ["landed [profile] profile/vehicle/settings screens (driver_app_plans/STATUS.md)"]
status: open
---

# [profile] Vehicle screen — enable the section, add the nav entry, add the suite

> **Open.** Closes driver bugs **#3** (the vehicle screen has no suite and
> `vehicleFeatureEnabled=false` makes it unreachable) and **#6** (`/vehicle` is reachable
> only by deep link — the drawer and the profile card omit it). Owner: `driver-planner`.
> Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see STATUS.md
> Verification).

## Gating decision (this plan's contract)

**The vehicle navigation entry is enabled now; the vehicle details/save surface stays
gated** on `ApiConfig.vehicleFeatureEnabled` (still `false` while `GET/PUT
/driver/me/vehicle` and `GET/POST /driver/me/documents` are `StubPayment` stubs —
`internal/router/router.go:219-222`). `/vehicle` therefore becomes a first-class drawer +
profile-card destination that renders the already-existing stub-honest **"Coming soon"**
state, so the section is no longer deep-link-only **without** building a saving surface on
a backend stub (STATUS Invariants). When the backend ships real endpoints, flipping
`vehicleFeatureEnabled` to `true` upgrades the same row to `_VehicleDetails` with no nav
change.

**Rejected alternative:** flipping `vehicleFeatureEnabled = true` today would render
`_VehicleDetails` from the `StubPayment` stub and force a rewrite of the "never build UI on
a backend STUB" invariant and the vehicle skip-list row. Not taken.

## Current state (verified)

- `driver_app/lib/config.dart:12` — `vehicleFeatureEnabled = false`; its comment says to
  flip it only once the backend ships the real endpoints.
- `driver_app/lib/features/vehicle/presentation/vehicle_screen.dart:25-34` —
  `VehicleScreen` already branches: `_VehicleDetails` (reads `GET /driver/me/vehicle` via
  `vehicleDetailsProvider`, `:9-17`) when enabled, `_ComingSoon` (`:36-65`) otherwise. **No
  test file exists** — `driver_app/test/features/vehicle/` is absent.
- `driver_app/lib/features/navigation/driver_nav_items.dart:23-25,35-39` — the vehicle row
  is gated by `includeVehicle = ApiConfig.vehicleFeatureEnabled` (default `false`), and
  both surfaces read this one list: the sidebar (`DriverShell`) and the profile card
  (`profile_screen.dart:97-105`).
- `driver_app/lib/core/router/app_router.dart:84-87` — `/vehicle` **is** registered inside
  the `ShellRoute`, so it works by deep link but has no nav affordance.
- Three suites pin the row's **absence** and must flip to presence:
  - `driver_app/test/features/navigation/driver_nav_items_test.dart:8-16,52-66` (incl. the
    `hasLength(4)` / id / route lists in the shipped-flag group);
  - `driver_app/test/features/navigation/driver_sidebar_test.dart:298-307`;
  - `driver_app/test/features/profile/presentation/profile_screen_test.dart:330-340`.
- **Drift found while authoring:** `profile_screen.dart:94` and
  `driver_nav_items_test.dart:57` cite "driver known bug #12" for this gate; the row is
  actually **#6** (#12 is the push cold-start test). Fix the comments as part of this plan.

## Deliverables

1. **Nav entry enabled.** Make the vehicle row unconditional — change the
   `buildDriverNavItems` default so `includeVehicle` defaults to `true` (keep the parameter
   so the gated case stays unit-testable). The row lands in `AppNavSection.activity`, before
   ride history; `driver_nav_items_test.dart:75-104` already pins that shape. Keep
   `vehicleFeatureEnabled` as the **details** gate only.
2. **Screen reachable + honest.** Keep `VehicleScreen`'s behaviour; only make its `enabled`
   value injectable for tests (a constructor parameter or a small
   `vehicleFeatureEnabledProvider`) so the `false` branch is exercised in the tree and the
   `true` branch is testable. The `false` branch stays the "Coming soon" disclosure and makes
   **no** network call; the `true` branch stays read-only — **never** add a `PUT
   /driver/me/vehicle` or `POST /driver/me/documents` call.
3. **New suite** `driver_app/test/features/vehicle/presentation/vehicle_screen_test.dart`:
   - flag off → renders the "Coming soon" copy and issues **no** request;
   - flag on (override) → `GET /driver/me/vehicle` through a mocked Dio, renders the returned
     `status`/`message`, plus the loading + error states;
   - no write request is ever issued.
   Follow the `mocktail` + `http_mock_adapter` conventions of the other feature suites
   (`driver_app/test/features/profile/...`, `.../safety/...`).
4. **Flip the three absence assertions to presence** (the row existing is what closes bugs
   #3/#6), fix the stale "bug #12" comments to "#6", and update the profile-screen comment at
   `profile_screen.dart:91-96`.

## Out of scope

- Any saving/write surface on the vehicle/documents endpoints (`PUT /driver/me/vehicle`,
  `POST /driver/me/documents` are `StubPayment` stubs — the authoritative skip list in
  `driver_app_plans/STATUS.md` stays).
- Flipping `vehicleFeatureEnabled` to `true` (a separate, backend-driven step).
- `shared/` — the nav model and the screen are driver-owned; no shared symbol changes.

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK (the /mnt/i/flutter SDK has CRLF endings)
melos run analyze
melos run test
```

- `melos run analyze` clean and `melos run test` green over `driver_app/`.
- The three flipped assertions and the new vehicle suite must pass; the driver test total
  increases by the new suite (re-count, do not trust a stale total).