---
tag: elevation
depends_on: ["elevation directional cost model + DEM ingest + default-on flip (STATUS.md, landed)", "actual trip distance + duration capture, migration 021 (STATUS.md [tracking], landed)"]
status: open
---

# Elevation duration-calibration dataset (the unnumbered chain head)

> **Unnumbered chain head.** Its only prerequisites are *landed capability*
> (`depends_on` above), so it names no open plan and does not earn an `NN_` prefix
> (`.opencode/skills/plan-management/SKILL.md`). It produces the dataset that
> **`01_[elevation]_duration_model.md`** consumes; that plan earns its `01_` because it now
> `depends_on` this open head.
>
> **Own plan, not folded in (user decision, recorded).** The duration model and the
> calibration dataset are different deliverables: this one is a *measurement artifact*
> (derive and document per-segment grade vs observed time), the model is a *code change*
> (fit and ship `v(g)`). Splitting them keeps the model plan from carrying an
> open-ended data-collection task as an unstated prerequisite.

**Status: OPEN — this is the blocker for `01_[elevation]_duration_model.md`.**

**The blocker is no longer "a driver-trace table does not exist."** It does: migration
`021_ride_actuals.up.sql:30` creates `ride_track_points(ride_id, lat, lng, recorded_at)`
(append-only, indexed `(ride_id, recorded_at)` at `:40-41`), populated while a ride is
`in_progress` (`internal/handler/geo.go:73-77`). What does **not** exist is a *derived and
documented* calibration dataset that joins those fixes to road-edge grades and yields
observed speed by signed grade. This plan is that derivation.

## Goal

Produce a documented, reproducible calibration dataset of per-segment
**signed grade `g`** and **observed travel time / speed** — enough to fit the speed-vs-grade
curve `v(g)` on the default (native) engine's data. This plan does **not** choose or fit
`v0 / kUp / kDown / vFloor`; that is `01_`. The deliverable is the measurement, its
provenance, its coverage, and the documented fit procedure the model plan follows.

## Source & join

Raw material. Completed rides' driver-fix traces:

- `ride_track_points` — migration `021_ride_actuals.up.sql:30-41`;
  `repository.InsertRideTrackPoint` (`internal/repository/ride_repo.go:336-341`),
  `repository.FindRideTrackPoints` ordered `recorded_at, id` (`:346-355`);
  `model.RideTrackPoint` (`internal/model/ride.go:97-103`).
- Per-ride actuals for qualification: `rides.actual_duration_s` / `rides.actual_distance_m`
  (migration `021_ride_actuals.up.sql:26-28`; `model.Ride` `internal/model/ride.go:54-55`),
  computed on completion in `internal/service/ride.go:437-453`.

Grade assignment. The native graph already carries elevation and computes a **signed grade
per edge** as `dz / meters` — `Node.EleM` (`internal/routing/routing.go:20-25`), the
per-edge walk `dz := g.nodes[path[i]].EleM - g.nodes[path[i-1]].EleM`
(`internal/routing/routing.go:352`), and `weightedEdgeCost`'s `g := dz / meters`
(`internal/routing/elevation.go:55-63`). Vertex elevation is loaded from
`road_network_vertices_pgr.elevation_m` via `toRoutingNodes`
(`internal/repository/navigation_repo.go:655-664`), and edges from
`road_network_edges_pgr(source, target, cost)` (`:617-618,671`). The derivation tool reuses
this same graph (do not re-implement the load or the grade formula), so the grade assigned to
a segment is exactly the grade the router would use for that edge under the shipped
`DeadbandM`.

Join algorithm (per completed ride):

1. Take the ride's fixes in `recorded_at` order.
2. Reuse the **existing** noise/teleport gates verbatim so the dataset and the fare actuals
   agree on what a "segment" is: `minFixSegmentM = 3.0` (jitter floor,
   `internal/service/ride_tracking.go:24`) and `maxPlausibleSpeedMps = 60`
   (teleport gate, `:30`), with the same drop-and-re-anchor rule and non-increasing-timestamp
   drop (`DrivenDistanceMeters`, `:58-89`). A gated-out fix is recorded as excluded, not
   silently discarded.
3. For each accepted segment, snap its mid-point (or both endpoints) to the nearest graph
   node/edge via the graph's grid index (`Graph.NearestNode`, `internal/routing/routing.go:154`;
   grid ref `:180`). A segment whose endpoints snap to different edges is attributed to the
   edge of the higher-coverage share, and its mate is recorded as `ambiguous`.
4. `g = dz / meters` for that edge, clamped to the configured `MaxGrade`
   (`internal/routing/elevation.go:58`), so a DEM artifact cannot produce a 40 % grade sample.
5. Time is the wall-clock `recorded_at` delta; an accepted segment carries
   `speed_mps = seg_m / dt_s`.

Qualifying rides (all must hold): status `completed`; ≥ 2 usable fixes after the gates;
non-NULL `actual_duration_s` **and** `actual_distance_m`; every accepted segment snaps
within a fixed snap tolerance to the same `routing_regions` row that owns the ride (cross-region
/ uncovered traces are excluded, never guessed).

Known accuracy limits to state in the dataset's provenance block (do not hide them): the
fix-to-fix distance is a **straight-line lower bound, not map-matched**
(`internal/service/ride_tracking.go:53-57`); sparse/throttled fixes undercount curves and
switchbacks; wall-clock `recorded_at` includes any dwell while fixes keep arriving; there is no
accuracy-radius, heading or per-fix elevation filtering. Because the lower bound biases
distance down, the derived **speed is biased low** — the fit must be honest about that
direction, and the dataset must record it.

## Deliverable

1. **A reproducible derivation tool** — intended as a Go command under `cmd/`
   (working name `cmd/calibtool`, matching the existing `cmd/elevtool` / `cmd/faretool`
   pattern). Requirements: **read-only** against every datasource (no `INSERT`/`UPDATE`/`DELETE`),
   **deterministic** (stable ordering, fixed ride id order, fixed rounding), a fixed
   seed/split id so two runs are byte-identical, and safe on the real DB (a failure or an
   unreadable datasource degrades to "skip that region", never a partial-write or a crash).
   An equivalent reviewed SQL/script derivation is acceptable only if it is equally
   read-only and deterministic and lives in the repo.
2. **The dataset artifact + schema** — written to a documented path in the repo (proposal:
   `data/elevation_duration_calibration/` with the raw segment table and the aggregated
   bin table). Per-segment row schema (proposal): `ride_id, region_id, segment_index,
   t_start, t_end, dt_s, seg_m, matched_edge_id, dz_m, grade, speed_mps, accepted, exclusion`.
   Aggregate bin table: `grade_bin_lo, grade_bin_hi, segments, distance_m, time_s,
   mean_speed_mps, variance`.
3. **A documented fit procedure** — the exact inputs, weights, bin edges, split rule and
   outlier policy `01_` must use, plus the residuals/robustness method (not the fitted
   constants).
4. **Provenance / size / grade-coverage reporting** — a manifest recording: source DB(s) and
   import date, region(s), number of qualifying rides, accepted segments, total accepted
   distance, the per-grade-bin coverage histogram, and the fraction of accepted distance that
   was actually grade-matched (vs `ambiguous`/`unmatched`).

## Quality controls

- **Distance-weighted aggregation.** Aggregate by `distance_m`, not by segment count: one
  long flat motorway segment must not be outweighed by many short jittery city segments.
- **Binning.** Fixed signed-grade bins over `[-MaxGrade, +MaxGrade]` (proposal: 0.01 width,
  with a wider over/underflow bin), so the fitted curve's domain is fixed by the data, not
  chosen after seeing the fit.
- **Outlier policy.** Drop a segment whose implied speed is outside a plausible road range
  (not just the 60 m/s teleport gate) and downgrade, not silently delete, the tail; report the
  trimmed fraction. One ride contributes at most one sample per edge per pass, so a
  circling driver cannot stuff a bin.
- **Held-out split.** Deterministic split by `ride_id` (proposal 80/20, hash-based) so the fit
  and its residual check use disjoint rides; both split assignments are stored in the artifact.
- **Grade coverage.** Assign each accepted segment to a split, a bin and an outlier class,
  and sum distance per cell, so a bin that is thin by ride, by distance or by region is
  visible.
- **Acceptance bar.** The dataset is *sufficient to fit* only if, after gating, the
  distance-weighted sample clears a documented minimum per reported grade bin (proposal:
  ≥ 500 accepted segments and ≥ 100 km per populated bin, and ≥ 20 distinct rides in each
  split's uphill **and** downhill populated bins). If a bin is under-populated, it is reported
  as under-populated — it is not extrapolated.
- **Fallback when coverage is insufficient.** If the acceptance bar is not met (likely on a
  single-city import), the documented alternative is an **external speed-by-grade reference
  with provenance** (a published road-speed / grade study), used only if its grade definition,
  road class and speed unit are reconciled and recorded here. **If neither the derived
  dataset nor a reconciled external reference exists, this plan stays blocked and `01_` must
  not choose constants — a blocked plan that says so is more honest than a tuned guess.**

## Non-goals

- Choosing `v0 / kUp / kDown / vFloor` or any fitted constant (that is `01_`).
- Implementing the duration model, touching `routing.Path` / `RouteResult` / `total_duration_s`,
  or changing the native engine's search.
- Changing routing or fare behavior at all; the dataset derivation is read-only and changes no
  served response.
- Exposing the driver trace on the ride JSON or building a map-matching / road-snapping
  product feature.

## Verification (all read-only)

- **Counts.** `SELECT count(*) FROM ride_track_points`; qualifying rides =
  completed rides with `actual_duration_s IS NOT NULL AND actual_distance_m IS NOT NULL` and
  ≥ 2 usable fixes. The manifest's numbers must equal a fresh query.
- **Grade-coverage histogram.** Distance-weighted counts per grade bin; sum of populated bins
  equals accepted distance (within rounding). Report matched vs `ambiguous`/`unmatched`.
- **Determinism.** Run the tool twice against the same DB and `diff` the two artifacts
  byte-for-byte; any difference is a bug, not noise.
- **Read-only proof.** Review the tool for zero write statements; run it against a DB role /
  connection that cannot write (or inside a `READ ONLY` transaction). No migration, no
  `INSERT`/`UPDATE`/`DELETE`.
- **Artifacts exist at the documented path** with the manifest (provenance, size,
  grade coverage, split) and the documented fit procedure; `01_` can be executed from the
  artifact alone.
- `gofmt -w <files> && go vet ./...`; `make lint` clean (when the tool is built).

## Cross-refs

- **Consumer:** `01_[elevation]_duration_model.md` — the code change that fits and ships
  `v(g)`; it is blocked until this head lands.
- **Landed source:** `api_plans/STATUS.md` → Landed → `[tracking]` (actual trip distance +
  duration, migration 021) and Landed → `[elevation]` (cost model, DEM ingest, default-on
  flip; `Node.EleM` / per-edge grade).
- **Invariant:** distance stays true meters; this dataset is telemetry and must not become a
  served response or a fare input by itself.
