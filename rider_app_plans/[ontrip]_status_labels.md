---
tag: ontrip
depends_on: []
status: open
---

# [ontrip] Honest per-status label on the rider status chip

> Owner: `rider-planner`. Verify: `melos run analyze` + `melos run test` (Linux FVM SDK — see
> Verification). **Independent** — the prerequisite is landed capability named in
> `rider_app_plans/STATUS.md`, so this file is **unnumbered**.
>
> **Sibling, not a duplicate:** `rider_app_plans/[ontrip]_driver_arrival_eta.md` owns the ETA row’s
> per-status semantics (D1 there: `driverArrived` shows an arrived state, `onTrip` shows no
> arrival countdown). This plan owns the **status chip label** only. The two must agree on the
> arrived wording (see Open inputs #1) — implement them together or reconcile before landing.

## The bug

The rider status chip shows the generic fallback `Matching` for every status that is not
`driverApproaching` / `onTrip` / `completed` — including `driverArrived`, the exact request:
“after the driver clicks Arrived at pickup, the rider status still says Matching.”

- `_getStatusText` `rider_app/lib/features/home/presentation/active_ride_screen.dart:786-797`:
  `driverApproaching`/`onTrip`/`completed` cases, then `default: return 'Matching'`.
- Backend → enum mapping is correct and already landed: `_statusFromBackend`
  `rider_app/lib/features/home/data/ride_status_provider.dart:158-177` maps `driver_arrived` →
  `RideStatus.driverArrived` (`:164-165`); the enum is `:8`:
  `matching, driverApproaching, driverArrived, onTrip, completed, cancelled, noDriverAvailable, idle`.
- The chip renders `AppStatusChip(label: statusText)` `active_ride_screen.dart:711`, with
  `statusText` computed at `:653`.
- The matching screen already uses the honest copy `Finding your driver...`
  (`rider_app/lib/features/home/presentation/driver_matching_screen.dart:165`), so the chip’s
  `Matching` is doubly inconsistent.

## Required mapping (recommended — make the switch exhaustive)

| `RideStatus` | Chip label |
| --- | --- |
| `matching` | `Finding your driver` (align with `driver_matching_screen.dart:165`) |
| `driverApproaching` | `Driver Approaching` |
| `driverArrived` | `Driver arrived` (the fix) |
| `onTrip` | `On Trip` |
| `completed` | `Completed` |
| `cancelled` | `Cancelled` |
| `noDriverAvailable` | `No drivers found` |
| `idle` | a neutral label (no ride) — not `Matching` |

Replace the `default:` with explicit cases for **every** enum value (and drop the `default`), so a
future status forces a label decision instead of silently reading `Matching`.

## Decisions to lock

- **D1 — `driverArrived` wording:** `Driver arrived` (recommended; it is the truthful state — the
  driver *has* arrived). The request’s “waiting for driver” describes the pre-arrival
  (`driverApproaching`) state and would be inaccurate here. Confirm with the ETA plan’s arrived
  copy.
- **D2 — `cancelled` / `noDriverAvailable` / `idle` copy** as in the table (or the product owner’s
  wording).
- **D3 — Exhaustiveness:** no `default` (recommended) vs a defensive fallback. If a fallback is
  kept, it must not be `Matching`.

## Boundaries

- **Rider-only, app-local.** No `shared/`, API or driver change; `AppStatusChip` is already the
  shared component and is only given a different label.
- Does **not** touch the `trip-eta` row or the driver sheet’s other status-dependent rendering
  (owned by `[ontrip]_driver_arrival_eta.md`).

## Tests (new / changed)

| Test | File | Asserts |
| --- | --- | --- |
| `driverArrived` chip | `rider_app/test/features/home/presentation/active_ride_screen_test.dart` (new) | after a `ride.updated` with `status: 'driver_arrived'` (and/or a `GET /rides/{id}` with that status), the chip renders `Driver arrived` and **not** `Matching` |
| `matching` chip | same file (new) | `pending`/`matching` renders `Finding your driver`, not `Matching` |
| terminal chips | same file (new) | `cancelled` / `no_driver_available` render their labels (and never `Matching`) |
| Existing chip control | same file `:416` | `Driver Approaching` still renders (unchanged) |

## Verification

```bash
export PATH=~/fvm/default/bin:$HOME/.pub-cache/bin:$PATH   # Linux FVM SDK + Melos 8
melos run analyze
melos run test
```

- `melos run analyze` must be clean; `melos run test` green across rider / driver / shared.
- **UNVERIFIABLE in this WSL harness:** nothing Android-specific; this is pure widget logic.
- `make flutter-analyze` / `make flutter-test` are **broken from this WSL tree** — do not use them.

## Open inputs / unknowns

1. **Arrived wording coordination** with `[ontrip]_driver_arrival_eta.md` D1 (the ETA row’s
   arrived copy); the chip and the ETA row must not disagree.
2. D2 final copy for `cancelled` / `noDriverAvailable` / `idle`.

## Invariants touched (from STATUS.md)

- Do not remove public providers / break the re-export-shim structure; this is a label change in
  the consuming screen only.
- The status set stays consistent with `_statusFromBackend` (`ride_status_provider.dart:158-177`);
  no new enum value is introduced.
