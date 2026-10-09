---
tag: elevation
depends_on: ["[elevation]_duration_calibration_data.md"]
status: open
---

# Grade-aware `total_duration_s` (Item B of the retired duration/API-surface plan)

> **`01_` — dependent stage of the elevation-duration chain.** It `depends_on` the **open** chain
> head `[elevation]_duration_calibration_data.md`, which is exactly what earns the `NN_` prefix
> (`.opencode/skills/plan-management/SKILL.md`). The head produces the per-segment grade-vs-speed
> dataset; **this** plan fits and ships `v(g)`. It replaces Item B of
> `01_[elevation]_duration_and_api_surface.md`, whose Item A (additive response fields) **landed**
> and which has been deleted as a landed plan. Item C is split out as the unnumbered
> `[elevation]_pgrouting_parity.md`.

**Status: OPEN — blocked on the calibration dataset head `[elevation]_duration_calibration_data.md`.**

**User decision (recorded):** the duration model is its own plan and **calibration comes first**:
fit a speed-vs-grade curve against real drive times *before* choosing constants. **The time fare
follows the new duration** — quotes will change, and that is accepted, not a regression to avoid.

## Goal

Replace the flat `total_duration_s = total_distance / 11` with a grade-aware duration derived
from a speed-vs-grade model, on the native engine. Distance stays true meters (series invariant);
only the time component changes.

Today: `avgSpeedMps = 11` at `internal/service/navigation.go:18`; `RouteInfo.DurationSecs` is set
from `totalDistance / avgSpeedMps` in `routeInfo` (`internal/service/navigation.go:295,313`) and
`estimateRoute` (`:325,333`). One flat ~40 km/h for every edge, flat or 15 % grade.

## The model (all constants PROVISIONAL until calibrated)

In the same per-edge walk that already produces `Meters` / `Cost` / `AscentM` / `DescentM`,
accumulate a per-edge time from the signed grade `g = dz / meters`:

```
v(g) = v0 / (1 + kUp·g)          for g > 0   (uphill slows)
v(g) = v0 · (1 − kDown·|g|)      for g < 0   (downhill speeds up, bounded)
v(g) = max(v(g), vFloor)
DurationS += meters / v(g)
```

Proposed constants — **placeholders, not findings**:

| constant | provisional | note |
|---|---|---|
| `v0` | 13.9 m/s (~50 km/h) | free-flow reference speed |
| `kUp` | 0.35 | uphill sensitivity |
| `kDown` | 0.15 | downhill sensitivity |
| `vFloor` | 2.5 m/s (~9 km/h) | real-ramp floor; keeps `g=MaxGrade` finite |

They must be fit against **real drive times** (see *Calibration data prerequisite*). A wrong
speed curve produces confidently wrong ETAs and wrong fares; the calibration head's G6 deadband
lesson (a provisional 3.0 shipped untested) is the precedent not to repeat.

## Blast radius (do not discover at the end)

1. **`routing.Path`** gains `DurationS float64`, accumulated in the same edge walk
   (`internal/routing/routing.go`, the `RouteWithWeights` search). `Path` currently carries
   `Nodes/Meters/Cost/AscentM/DescentM/Expanded` (`internal/routing/elevation.go:42`).
2. **`repository.RouteResult`** gains `DurationS` (last-row convention, like `AggCost` / the
   elevation totals) at `internal/repository/navigation_repo.go:15`, populated in `routeResults`
   (`:749`).
3. **`tests/testutil/mock_navigation_repo.go` must explicitly emit 454 s**
   (`(5000 m)/11 = 454.54 → 454`). It currently emits only `AggCost=5000`
   (`tests/testutil/mock_navigation_repo.go:13-17`), so a duration field left at zero would
   silently turn every mock-backed route into 0 s. Every `454` assertion must be re-checked:
   `tests/ride_lifecycle_test.go:114-115`, `tests/routing_test.go:57,128`.
4. **`service` fallback** — `routeInfo`/`estimateRoute` switch to the computed `DurationS` when
   the repo supplies one, with a **documented fallback to `distance/avgSpeedMps`** when it does
   not (0). Without it, the estimate path and every mock silently report 0 s. Do not delete
   `avgSpeedMps`: it stays the fallback constant.
5. **`FareService` time component** prices from it — `timeFare = (dur/60)·timeRate`
   (`internal/service/fare.go:159`). The quoted fare is **snapshotted onto the ride at booking**
   (`internal/service/ride.go:217,239-247`), so a wrong duration model is wrong **money**,
   permanently, for every ride quoted while it is deployed. Both apps display duration and need
   no code change, but riders will notice.

## Calibration data prerequisite (the actual blocker)

**The raw trace exists; the calibrated dataset does not.** Migration
`internal/database/migrations/021_ride_actuals.up.sql:30` already writes an append-only
per-ride driver-fix trace `ride_track_points(ride_id, lat, lng, recorded_at)` while a ride is
`in_progress` (`internal/handler/geo.go:73-77`), and completion derives actual distance/duration
from it (`internal/service/ride_tracking.go:58-89,94-103`; `internal/service/ride.go:437-453`).
What is missing is the **derived, documented dataset** that joins those fixes to road-edge signed
grades and yields observed speed by grade. That derivation — source, join, tool, schema,
quality controls, coverage reporting and fallback — is the open chain head
**`[elevation]_duration_calibration_data.md`**; this plan `depends_on` it and must not start
fitting until it lands. Only then fit `v0/kUp/kDown/vFloor`. **If the head cannot meet its
acceptance bar (or reconcile an external speed-by-grade reference), this plan stays blocked and
must not choose constants from the literature and call it calibration.** A blocked plan that says
so is more honest than a tuned guess.

## Suggested sequence (once the head lands)

1. Read the dataset artifact and its manifest from
   `[elevation]_duration_calibration_data.md`; do not re-derive the data here.
2. Fit `v(g)`; record the fitted constants, the residuals, and the sample split.
3. Implement the model as above; keep the flat fallback.
4. Re-run `make test` and grep the suite for `454` before/after — the count of assertions on the
   mocked duration moving is the contract moving.
5. Update `FareService` expectations/tests; note the quote change is intended.
6. Land via the standard lifecycle (STATUS.md Landed + adversarial verification).

## Verification (when built)

- `make test` green; grep the suite for `454` before and after and account for every change.
- A live curl showing `total_duration_s` differs from `distance/11` on a hilly pair and equals the
  face value of the fitted curve; the flat fallback still holds when the repo supplies no duration.
- `FareService` estimate tests updated for the new time component; booked-fare snapshot still
  carried unchanged through completion (`internal/service/ride.go:175`).
- `gofmt -w` + `go vet ./...`; `make lint` clean.
