---
tag: routing
depends_on: ["[routing]_gate_correctness.md"]
status: open
---

# Plan: Valle Central — one Central Valley routing region (`valle_central`)

**Chain stage `01`.** This plan now depends on an **open** plan,
`[routing]_gate_correctness.md` (the elevation coverage-gate fix, its §A5), because the basin
elevation backfill needs that fix first — so per the numbering rule it is
`01_[routing]_valle_central.md`. The gate plan is the **unnumbered chain head** (it depends only
on landed capability). This plan is **open** — nothing here is claimed landed, and every runbook
step below is unimplemented.

**Supersedes** the earlier `[routing]_nationwide_costa_rica.md` (renamed to this file; git history
is the archive). Its Option A/B/C question ("one whole-country `cr`, 7 provinces, or a hybrid") is
**closed by the product owner**: the answer is **one region covering the Central Valley basin**,
`region_id = 'valle_central'` — *not* nationwide, and *not* the 4 full provinces. The rider/driver
apps need **no** code change (§Contract).

---

## 1. Locked scope (product decision — do not re-litigate)

- **One region:** `region_id = 'valle_central'`, `level = 'state'`, `name = 'Valle Central'`,
  `parent_region = 'cr'`. The existing `cr` **country** row
  (`internal/database/migrations/013_region_schema.up.sql:40`) stays as the hierarchy parent and
  remains **empty** (no network data, `default_region = FALSE`).
- **Scope = the Central Valley BASIN only.** NOT the 4 full provinces: Alajuela province reaches
  the northern border (~lat 11.2) and San José province reaches the Pacific (~lat 9.0), so importing
  by province would import a large, partly coastal/mountain graph. Use the basin outline (polygon if
  available, box as fallback — §2).
- **Product:** within-basin trips road-follow; any pin outside the basin — including the rest of the
  4 provinces and any cross-basin trip — answers **200 `is_estimate`** with the straight haversine
  polyline (the honest fallback already landed, `internal/service/navigation.go:496-510`). Intercity
  stays deferred (`[routing]_intercity.md`).
- **Elevation gate fix is a prerequisite, owned by `[routing]_gate_correctness.md` §A5** (bug #24):
  one shared **0.99** ingest/runtime constant (align ingest UP) + a region-scoped post-import
  coverage assertion. It is **no longer scoped in this plan**; this plan only consumes it in
  runbook step 4. See §3.
- **`cr-sj` is deleted at the end.** Transition first (empty its network rows, flip the default),
  then the final cleanup deletes `fare_rates` → `fare_demand_windows` → `fare_regions` →
  `routing_regions`, guarded by "no active `cr-sj` ride". See §4. This **supersedes** the interim
  "keep `cr-sj` registry + fare for audit" position.
- **One fare card for `valle_central`**, seeded **before** the default flip (fail-closed 5xx without
  it — `internal/service/fare.go:188-191`). See §5.
- **Wire only.** `region_id` moves `"cr-sj"` → `"valle_central"` for **new** rides; **completed**
  rides keep their booked `cr-sj` audit value. No app keys on `region_id` (§Contract).

---

## 2. Region boundary — polygon preferred, box fallback (CONFIRM BEFORE IMPORT)

- **Preferred:** a hand-drawn **`regions/valle_central.poly`** (the `regions/` dir does not exist
  yet) for the exact basin border, used with `osmium extract -p`
  (`scripts/import-road-network.sh:51-58` documents the `.poly` extract idiom;
  `scripts/download-osm.sh:12-14` notes the swap for a precise `.poly`).
- **Fallback only if no `.poly`:** the operator box **`-84.45,9.65,-83.65,10.25`**
  (minLon,minLat,maxLon,maxLat). **State this as the CONFIRM-BEFORE-IMPORT value.** A bbox
  over-covers the basin's corners; a polygon is the intended clip.
- The importer refreshes the registry bbox from `ST_Extent` after import, so the box recorded in
  `routing_regions` converges to the imported geometry either way
  (`scripts/import-road-network.sh:67-70,121-123`).
- **Still-open input (do not silently pick):** the exact basin polygon/box. Confirm before step 2 of
  §Runbook.

---

## 3. Elevation coverage-gate fix — extracted to `[routing]_gate_correctness.md` §A5

The bug #24 fix (a shared `DefaultElevationMinCoverage = 0.99` ingest/runtime constant + a
region-scoped `import-elevation.sh` post-import assertion) is **no longer scoped in this plan**.
It has been extracted to the chain head `[routing]_gate_correctness.md` §A5, and this plan
**depends on** it: runbook step 4 (the `valle_central` elevation backfill) is only correct once
the ingest gate is aligned up and the coverage assertion is region-scoped.

Do not re-decide the fix here. Implement and verify it in the gate plan, then run step 4 below.

Backfill the basin with `./scripts/import-elevation.sh --region valle_central` (§Runbook step 4).

---

## 4. `cr-sj` lifecycle — transition, then delete all (LOCKED)

> The `cr-sj` row is retired. Its network is emptied at transition; the remaining registry + fare
> rows are deleted at the end, once `valle_central` is serving and no `cr-sj` ride is in flight.

**A. Transition (in §Runbook steps 6–7).**

1. Empty the `cr-sj` **network** rows, **edges before vertices** (composite FKs
   `road_edges_source_fkey` / `road_edges_target_fkey` → `road_vertices`,
   `internal/database/migrations/013_region_schema.up.sql:126-133`):
   `road_edges → road_vertices → road_network_edges_pgr → road_network_vertices_pgr`.
2. Make `valle_central` the **single** `default_region = TRUE` owner
   (`UPDATE routing_regions SET default_region = (region_id = 'valle_central')`).
   Emptying `cr-sj`'s network first means the resolver's snap-first walk
   (`internal/service/navigation.go:380-408`) simply falls through the now-vertex-less `cr-sj`
   candidate to `valle_central`.

**B. Final cleanup (in §Runbook step 8, after `valle_central` serves and no `cr-sj` ride is live).**

Delete in **FK order** (forced by:
`fare_rates.region_id → fare_regions(region_id)` `019_region_fares.up.sql:44`;
`fare_demand_windows.region_id → fare_regions` `019:67`;
`fare_regions.region_id → routing_regions(region_id)` `019:23`):

```sql
DELETE FROM fare_rates           WHERE region_id = 'cr-sj';
DELETE FROM fare_demand_windows  WHERE region_id = 'cr-sj';
DELETE FROM fare_regions         WHERE region_id = 'cr-sj';
DELETE FROM routing_regions      WHERE region_id = 'cr-sj';
```

**Guard — require no active `cr-sj` ride before the delete.** A live `cr-sj` ride completing after
the delete would look up its booked card by id
(`internal/service/fare.go:310-321` `RecomputeActualFare` → `GetFareRateByID`, `fare_repo.go:87`)
and find it gone. Check first:

```sql
SELECT count(*) FROM rides
WHERE fare_region_id = 'cr-sj'
  AND status NOT IN ('completed', 'cancelled');   -- must be 0
```

Completed/cancelled rides never recompute again (exactly-once, `FinalizeRideFare` guarded on
`quoted_total_fare IS NULL`), so they are safe. Even if the guard is bypassed, the recompute error
is returned to the caller, which logs it and **falls back to the booked quote unchanged**
(`fare.go:300-305,318-321`) — no crash, no fabricated fare; the guard just preserves the recompute.

**Accepted residual (state it):** `rides.fare_region_id` / `rides.fare_rate_id` are **plain audit
columns with no FK** by design (`internal/database/migrations/019_region_fares.up.sql:80-85`), so
historical rides keep **stale** `cr-sj` audit refs after the delete. Every read path echoes the
stored value (receipt `region_id`/`fare_region_id`), so historical display is preserved; nothing
dereferences the deleted registry row.

**Reversibility:** `cr-sj` can be re-imported from the province extract
(`./scripts/import-road-network.sh --region cr-sj --force ...`) and re-seeded; the valley import
destroys nothing a re-import cannot recreate. The final delete is intentionally **not** a boot
migration (data readiness stays in the ordered runbook), same rationale as the default flip.

---

## 5. Fares — one `valle_central` card, before the flip

`make seed-fares SEED_FARES_REGION=valle_central SEED_FARES_TIMEZONE=America/Costa_Rica`
(default is `cr-sj`, `Makefile:51-56`). A region with no active card fails closed 500
(`internal/service/fare.go:188-191`), so the card ships **before** the default flip (step 5 before
step 6). `cr-sj`'s cards are not deleted until the final cleanup (§4B).

---

## 6. Current state (verified, with evidence)

| Fact | Evidence |
| --- | --- |
| Region registry: `cr` country (rough box, empty) + `cr-sj` state (`default_region=TRUE`) seeded. | `internal/database/migrations/013_region_schema.up.sql:37-42` |
| Resolution is snap-first over candidates ordered by **bbox-center proximity**, first real snap wins, then a default-region fallback; no parent-chain escalation. | `internal/service/navigation.go:380` (`resolveRegion`), `:391` (`orderRegionsByProximity`), `:396,:404` (`Snap`), `:415-418` (default attempt) |
| Uncovered pickup → 200 `is_estimate`; dropoff owned by another region → 200 estimate. | `internal/service/navigation.go:149`, `:161`, `:182`, `:190`; `estimateRoute` `:496-510` |
| Import is one region per run, `--region` defaults `cr-sj`; self-registers the row, imports region-scoped, refreshes bbox from `ST_Extent`, supports `--level/--name/--parent/--default`, per-region wipe. | `scripts/import-road-network.sh:64,67-77,94-103,121-127` |
| Clip helper supports `--region <id> --bbox`; `.poly` via `osmium extract -p` is the documented idiom. | `scripts/download-osm.sh:12-14,22-33,56-60,90-92`; `scripts/import-road-network.sh:51-58` |
| Whole-country extract already downloaded. | `scripts/download-osm.sh:9-10`; `data/costa-rica-latest.osm.pbf` |
| Elevation ingest accepts `--region`; the ingest gate (**0.98**) still trails the runtime gate (**0.99**) and the post-import assert is **global** — the gate-mismatch prerequisite tracked by `[routing]_gate_correctness.md` §A5. | `cmd/elevtool/main.go:55,56`; `scripts/import-elevation.sh:23,36-38,43-45`; `internal/config/config.go:181`; `internal/repository/navigation_repo.go:439-441` |
| Fares are per-region and fail closed: a `region_id` with no active card → 500; default card comes from the single `default_region=TRUE` row. | `internal/database/migrations/019_region_fares.up.sql:22-28,42-55`; `internal/service/fare.go:188-191`; `internal/repository/fare_repo.go:118-123`; `Makefile:51-56` |
| `rides.fare_region_id`/`fare_rate_id` are audit-only (**no FK**), so historical rows survive a registry delete. | `internal/database/migrations/019_region_fares.up.sql:80-85` |
| Apps do not key on `region_id` (no reference in `rider_app/lib`, `driver_app/lib`, `shared/lib`). | `grep -rn "region_id\|regionId" rider_app/lib driver_app/lib shared/lib` → 0 matches |
| `cr-sj` appears in production Go only as a doc-comment example + the migration seed; every other literal is a test fixture/fake. | `cmd/faretool/main.go:8`; `internal/model/region.go:12`; `013_region_schema.up.sql:41`; tests under `internal/**` + `tests/` |

**Non-gap:** the country extract and `.poly` clipping already exist as tooling; no new schema, no
`NavigationRepository` signature change, and no migration for the graph itself.

---

## 7. Design — what actually changes

1. **Network:** import the basin extract into a **new** `valle_central` row (`level='state'`,
   `parent_region='cr'`), region-scoped; bbox refreshed from `ST_Extent`. No schema change.
2. **Elevation gates:** a prerequisite owned by `[routing]_gate_correctness.md` §A5 (shared 0.99
   Go constant + region-scoped `import-elevation.sh` assertion). No code change is scoped here.
3. **`cr-sj` transition:** empty its network rows (edges before vertices); single `default_region`
   owner = `valle_central`.
4. **Fares:** seed the `valle_central` card before the default flip.
5. **Restart** the API so the in-process graph cache reloads (AGENTS.md fact 5).
6. **Final cleanup:** delete `cr-sj` fare + registry rows in FK order, guarded by "no active
   `cr-sj` ride" (§4B).

---

## 8. Runbook (exact commands)

> Ordering matters: gate fix → backfill → seed the fare card **before** flipping `default_region` →
> restart → **final delete last**, only after `valle_central` serves and no `cr-sj` ride is in
> flight. A missing card on the default region is a fail-closed 500.

```bash
# 0. DB up; migrations apply on API boot
docker compose up -d

# 1. country extract (already present; re-download only if stale)
./scripts/download-osm.sh                       # data/costa-rica-latest.osm.pbf

# 2. clip to the CONFIRMED basin border. Preferred: exact basin border
#    (create regions/valle_central.poly first):
osmium extract -p regions/valle_central.poly data/costa-rica-latest.osm.pbf \
  -o data/valle_central.osm.pbf
#    Box fallback if no .poly (CONFIRM-BEFORE-IMPORT):
#   ./scripts/download-osm.sh --region valle_central --bbox "-84.45,9.65,-83.65,10.25"

# 3. import into a new `valle_central` registry row
#    (self-registers; bbox is refreshed from ST_Extent after import)
/usr/bin/time -v ./scripts/import-road-network.sh \
  --region valle_central --bbox "-84.45,9.65,-83.65,10.25" \
  --level state --name "Valle Central" --parent cr \
  --force \
  data/valle_central.osm.pbf

# 4. region-scoped elevation backfill (fetches only the basin's skadi tiles).
#    Requires the gate fix first: [routing]_gate_correctness.md §A5 (shared 0.99 ingest
#    gate + region-scoped assert).
./scripts/import-elevation.sh --region valle_central

# 5. fare card BEFORE the default flip (fail-closed 500 without it)
make seed-fares SEED_FARES_REGION=valle_central SEED_FARES_TIMEZONE=America/Costa_Rica

# 6. retire the cr-sj NETWORK (edges BEFORE vertices, composite FKs,
#    013_region_schema.up.sql:126-133); make `valle_central` the single default.
psql "$DATABASE_URL" <<'SQL'
DELETE FROM road_edges                 WHERE region_id = 'cr-sj';
DELETE FROM road_vertices              WHERE region_id = 'cr-sj';
DELETE FROM road_network_edges_pgr     WHERE region_id = 'cr-sj';
DELETE FROM road_network_vertices_pgr  WHERE region_id = 'cr-sj';
UPDATE routing_regions SET default_region = (region_id = 'valle_central');
SQL

# 7. restart the API (graph is cached in-process; AGENTS.md fact 5)
make run

# 8. FINAL cr-sj cleanup — run ONLY after `valle_central` is serving and the
#    guard below returns 0. Deletes in FK order (019_region_fares.up.sql:23,44,67).
psql "$DATABASE_URL" <<'SQL'
SELECT count(*) AS active_cr_sj_rides FROM rides
WHERE fare_region_id = 'cr-sj' AND status NOT IN ('completed','cancelled');
-- If active_cr_sj_rides <> 0, STOP. Re-run after those rides finish.
DELETE FROM fare_rates           WHERE region_id = 'cr-sj';
DELETE FROM fare_demand_windows  WHERE region_id = 'cr-sj';
DELETE FROM fare_regions         WHERE region_id = 'cr-sj';
DELETE FROM routing_regions      WHERE region_id = 'cr-sj';
SQL
```

**Why the flag flip is a runbook `UPDATE`, not a boot migration:** migrations auto-apply at
startup; on a deploy where the import (step 3) or the fare seed (step 5) has not run, a boot
migration flipping the default would make every uncovered estimate 5xx. Keep data readiness in the
operator's ordered runbook.

---

## 9. Contract (unchanged except the `region_id` value)

- `GET /api/v1/navigation/route` 200 shape is **unchanged**: `{polyline, total_distance_m,
  total_duration_s, total_ascent_m, total_descent_m, elevation_aware, is_estimate}`
  (`internal/handler/responses.go:246-257`).
- A pin outside the basin (or outside every imported region) still answers **200 `is_estimate`**
  with the straight haversine polyline, **never 4xx** (`internal/service/navigation.go:496-510`;
  STATUS.md invariant).
- On the wire `region_id` moves `"cr-sj"` → `"valle_central"` for new basin rides
  (`RouteInfo.RegionID`, set at `internal/service/navigation.go:202`). **No app reads or keys on
  `region_id`** (verified: 0 matches), so this is not a breaking change. **Completed** rides keep
  their booked `cr-sj` audit value.
- **No new shared Dart symbol.** `shared/` is untouched; the ADD-only re-export rule is not
  exercised. The only SJ-specific app literals are cosmetic pre-GPS map fallbacks
  (`rider_app/lib/features/home/presentation/home_screen.dart:56`,
  `driver_app/lib/features/trip/presentation/trip_screen.dart:330`) — out of this API plan, owned by
  the app planners.
- Docs to refresh on landing: `RIDER_API_GUIDE.md:342,564` still show `"region_id": "cr-sj"`
  example payloads.

---

## 10. Tests

No existing unit test hardcodes the migration-013 seed in a way this plan's routing changes break —
they use their own fixtures/fakes (`cr-sj` literals in `internal/service/regions_test.go`,
`internal/repository/fare_repo_integration_test.go`, `tests/testutil/mock_fare_repo.go`,
`tests/fare_snapshot_test.go`, … are independent of the persisted registry). **Do not churn them.**

**New coverage this plan should add (when implemented, not now):**
- A resolver test that an emptied `cr-sj` falls through to `valle_central` (extend the
  `TestResolveRegionWalksPastUncoveredCandidates` pattern in `internal/service/regions_test.go`).
- A DB-backed acceptance test that an in-basin pair returns `is_estimate=false`, while a pin
  outside the basin and a cross-basin pair return `is_estimate=true`.
- The elevation-gate tests (per-region coverage assert + the shared `DefaultElevationMinCoverage`
  pin) live in `[routing]_gate_correctness.md`; do not duplicate them here.

---

## 11. Verification

```bash
make test                       # unit tests, no DB (must stay green)
make lint                       # golangci-lint v2; 0 issues
make test-integration           # DB-backed (docker compose up -d first)
gofmt -w <files> && go vet ./...

# Acceptance (manual, DB-backed):
#   - two basin pins -> is_estimate=false, road-following polyline (len > 2 bends),
#     total_distance_m != straight-line haversine;
#   - a pin outside the basin (e.g. the coast or Guanacaste) -> 200 is_estimate=true;
#   - a new ride's region_id == "valle_central"; an old completed ride keeps "cr-sj";
#   - after step 8: SELECT count(*) FROM routing_regions WHERE region_id='cr-sj' = 0.
```

**WSL harness limits:** on-device/Android checks are **UNVERIFIABLE** here; Flutter is irrelevant to
this API plan. Do **not** reference `make flutter-*` (broken — AGENTS.md fact 1).

---

## 12. Open inputs / unknowns (surface — do not silently pick)

| Unknown | Resolve with |
| --- | --- |
| **Exact basin polygon/box** (§2) — CONFIRM-BEFORE-IMPORT | Product-owner / operator confirmation; prefer `regions/valle_central.poly` over the bbox `-84.45,9.65,-83.65,10.25` |
| **Any downstream (analytics / receipts / reporting) keyed on `cr-sj`** before the rename + delete | grep + confirm no table/query filters on the literal. Production Go has no `cr-sj` literal outside the migration seed + comments (verified); completed receipts read the stored `rides.fare_region_id` and echo it, so they are unaffected |
| Basin vertex/edge counts (size of the runtime graph) | `psql "$DATABASE_URL" -c "SELECT count(*) FROM road_network_vertices_pgr WHERE region_id='valle_central'" -c "SELECT count(*) FROM road_network_edges_pgr WHERE region_id='valle_central'"` |
| Import peak RSS (osm2pgrouting in-RAM graph) | `/usr/bin/time -v ./scripts/import-road-network.sh --region valle_central ...` |
| Runtime native-graph RSS | start server, issue one basin route to force the graph build, then `ps -o rss= -p "$(pgrep -f 'cmd/server')"` (KiB) |
| DEM tile set + fetch size for the basin | `go run ./cmd/elevtool -database-url "$DATABASE_URL" -region valle_central -dry-run` |

**Graph sizing / `ROUTING_MAX_REGIONS_IN_MEMORY`:** the current `cr-sj` province import is
**152,665 vertices / 183,372 edges** (`internal/database/migrations/013_region_schema.up.sql:16`).
The basin is **smaller in area** than that province box (measured counts are an *estimate to be
measured*, not asserted here). With `cr-sj`'s network emptied, exactly **one** region has a graph,
so `ROUTING_MAX_REGIONS_IN_MEMORY` (`internal/config/config.go:44-57`) is **moot** for this
deployment. No tuning required.

**Ops trigger:** runbook-only — one explicit import command + an optional `regions/valle_central.poly`.
**No** bbox-table / one-command provisioning system (the `scripts/PLACES_FROM_DB_BBOX.md` brainstorm
stays ignored).

---

## 13. Non-goals / references

- **Nationwide / per-province coverage is out of scope** (superseded). A pin outside the basin is
  an honest 200 `is_estimate`, not a coverage bug.
- **Intercity** (cross-region leg planning, overlay ports, parent-chain) stays deferred:
  `api_plans/[routing]_intercity.md`. This plan deliberately does not need it.
- **No** `scripts/PLACES_FROM_DB_BBOX.md` provisioning system, **no** bbox-table automation.
- Elevation duration model (`01_[elevation]_duration_model.md`) and pgRouting parity
  (`[elevation]_pgrouting_parity.md`) are untouched.
- Bug #24 (elevation coverage-gate mismatch) is fixed by `[routing]_gate_correctness.md` §A5, not
  here — see `STATUS.md` → Known bugs.
