---
tag: routing
depends_on: ["routing region resolution (STATUS.md)"]
status: open
---

# Plan: Nationwide Costa Rica — expand supported area from San José province to all of CR

**Chain head (unnumbered).** `depends_on` names *landed* capability (region resolution +
multi-city stack, `STATUS.md` → Landed `[routing]` 04/05/06), not an open plan, so the file is
`[routing]_nationwide_costa_rica.md` with no `NN_` prefix. This plan introduces no app-visible
contract change and no shared Dart symbol; the rider/driver apps need **no** change (see
§Contract).

This plan is **open** — nothing here is claimed landed. It closes the coverage gap that
`api_plans/STATUS.md` currently records as *San José province only*.

---

## 1. Current state (verified, with evidence)

| Fact | Evidence |
| --- | --- |
| Coverage today is one state-level region, `cr-sj`, `default_region=TRUE`. | `internal/database/migrations/013_region_schema.up.sql:37-42` |
| A `cr` **country** row already exists but has **no network data** (rough box, `default_region=FALSE`). | `013_region_schema.up.sql:40` |
| Resolution is snap-first over candidates ordered by **bbox-center proximity**, first real snap wins; no parent-chain escalation. | `internal/service/navigation.go:380` (`resolveRegion`), `:391` (`orderRegionsByProximity`), `:396` (`Snap`), `:434-447` |
| Uncovered pickup → 200 `is_estimate` straight line; dropoff owned by another region → 200 estimate (cross-region = deferred intercity). | `internal/service/navigation.go:148-150`, `:160-162` |
| Import is one region per run, `--region` defaults `cr-sj`; registers the row, imports region-scoped, refreshes bbox from `ST_Extent`, per-region partial GIST. | `scripts/import-road-network.sh:94,99,371-403,410-424,439-447,453-477` |
| Whole-country extract is already downloaded. | `scripts/download-osm.sh:9`; `data/costa-rica-latest.osm.pbf` (38 MB); `data/roads-filtered.osm` (138 MB) |
| Shipped snap radius is 50 km; default-region env unset; per-region graphs uncapped (0 = keep all) at ~150–200 MB each. | `internal/config/config.go:130`, `:229`, `:230`; `internal/repository/navigation_repo.go:270,287-331` |
| Fares are per-region and fail closed: a `region_id` with no active card → 500. | `internal/database/migrations/019_region_fares.up.sql:22-28,42-55`; `internal/service/fare.go:133`; `Makefile:51-56` |
| Elevation ingest accepts `--region`; runtime gate is **0.99**, ingest gate **0.98** (bug #24); the post-import coverage assert is **global**, not region-scoped. | `cmd/elevtool/main.go:55,56,188-201`; `internal/config/config.go:147,173,242`; `internal/repository/navigation_repo.go:439-441`; `scripts/import-elevation.sh:23,43-45`; `api_plans/STATUS.md:408` |
| Places are **already nationwide** (139,816 features across CR). | `internal/config/config.go:222-224`; `data/places.geojson` (139,816 `Feature`s) |

**Non-gap (do not "fix"):** `data/places.geojson` already spans Costa Rica and
`PLACES_MAX_RADIUS_M=50000` already covers rural search. No places work is required by this plan;
only the deployment requirement that the 70 MB `data/places.geojson` ships (see §Decision 4).

---

## 2. PIVOTAL OPEN DECISION — region granularity (recommendation first, not silently taken)

### Option A — ONE whole-country region (`cr`) **[RECOMMENDED]**

Import the full national road network into the existing `cr` country row so **every** in-CR pin
resolves to ONE region and **every** in-CR trip (including San José ↔ Guanacaste/Limón)
road-follows with **no intercity work**.

- **Consequence that must be stated and executed:** with `cr` populated you must **empty the
  `cr-sj` network rows** (`road_network_{vertices,edges}_pgr`, `road_edges`, `road_vertices`),
  otherwise the resolver's proximity ordering keeps sending San José (and near-border) pins to
  `cr-sj` and SJ ↔ rest becomes a cross-region estimate. The 50 km snap radius makes this worse:
  a non-SJ pin within 50 km of an SJ road would snap to `cr-sj`'s subgraph and route on the wrong
  graph. Do **not** delete the `cr-sj` **registry** row: `fare_regions.region_id` has an FK to
  `routing_regions` and completed rides keep a `fare_rates` PK reference, so the row and its fare
  data must survive as audit (see §Decision 1/3).
- **Cost:** one large in-memory graph (national). Revisit `ROUTING_MAX_REGIONS_IN_MEMORY`
  (irrelevant with one region) and replace the per-region ~150–200 MB figure with a measured
  national number (§Open inputs).
- **Benefit:** eliminates province-boundary mis-snapping and cross-region estimates in one move;
  no dependence on the deferred intercity seam.

### Option B — Per-province regions (7 states)

Import each of the 7 provinces as its own region (`cr-sj`, `cr-al`, `cr-ca`, `cr-he`, `cr-gu`,
`cr-pu`, `cr-li`) with `--parent cr`. Local routes are real; **every cross-province trip stays a
straight-line estimate** until intercity lands. Uses the already-built multi-region eviction and
smaller graphs.

- **Tradeoff:** honest but does **not** satisfy "support all of Costa Rica" for long trips, and the
  50 km radius can still snap a border pin into the *wrong* province's subgraph.
- **Cost:** 7 fare cards (one per region), 7 elevation backfills, per-province clips.

### Option C — Hybrid / parent-chain fallback

Keep local regions and route cross-region through a populated parent `cr` graph. This is exactly
the deferred seam documented in `api_plans/[routing]_intercity.md` (overlay ports + parent-chain
leg planner). If chosen, scope this work **against that plan**; do not invent a second design here.
Substantially larger than A/B (ports schema, leg planner, chaining tests).

**Recommendation: A.** It is the smallest change that honestly satisfies the stated goal (every
in-CR trip road-follows), it needs no new schema and no intercity machinery, and it removes the
province-boundary failure mode rather than working around it. B is the fallback if a single
national graph is measured to be operationally too large; C is a separate, larger program.

---

## 3. Other decisions to surface (options + recommendation; do not silently pick)

1. **`cr-sj` row fate & `default_region` owner.**
   - Options: (a) keep the `cr-sj` routing_regions row + fare_regions/cards, empty only its
     **network** rows, flip `default_region` to `cr`; (b) delete the row.
   - (b) is blocked/non-viable: `fare_regions.region_id` FK (`019_region_fares.up.sql:23`) and
     completed rides' `rides.fare_rate_id` PK references (`internal/service/fare.go:310-321`)
     mean deleting the card breaks the completion recompute's booked-card lookup
     (`repository.GetFareRateByID`, `fare_repo.go:87-101`).
   - **Recommend (a).** `DefaultRegionID()` requires exactly the `default_region=TRUE` row
     (`fare_repo.go:118-128`); `'cr'` sorts before `'cr-sj'`, so if both are TRUE `cr` would win
     the fare default but the *resolver's* `defaultRegion` would still pick the nearest flagged
     row — make the flag single-owner (`cr`) rather than relying on sort order.

2. **Elevation nationwide.**
   - Per-region DEM backfill (fetch the extra skadi tiles for lon −86..−82 / lat 8..11);
     **fix `scripts/import-elevation.sh:43-45` to assert coverage over the imported region only**
     (`... WHERE region_id = :'region'`) when `--region` is passed; and **align ingest 0.98 vs
     runtime 0.99 (bug #24, `STATUS.md:408`)** — a region that imports at 0.98–0.989 silently
     serves flat routing on the now-default path.
   - **Recommend:** do the region-scoped assert as part of this work (it is a prerequisite for a
     multi-region or defunct-`cr-sj` import to pass at all). Close bug #24 by a shared coverage
     constant (aligning the ingest gate up to 0.99, or a single exported constant used by
     `cmd/elevtool` + `config`). If the `[elevation]` owner opens a separate plan for bug #24
     first, this plan's `depends_on` must gain that open-plan target and be renumbered `01_`.

3. **Fares.** One card per region. Each new/used `region_id` needs a `fare_regions` row + one
   active `fare_rates` card (fail-closed 5xx otherwise), seeded with explicit
   `--region/--timezone` (`cmd/faretool/main.go`; `Makefile:51-56`).
   - Option A: one national card `make seed-fares SEED_FARES_REGION=cr` (+ keep `cr-sj`'s rows for
     historical recompute).
   - Option B: 7 cards.
   - **Recommend Option A.** A shared national card is exactly what one region means; no
     cross-region fallback is needed because there is one region.

4. **Places (confirmed non-gap).** `data/places.geojson` (139,816 features) must ship and
   `PLACES_GEOJSON_PATH` point at it (`config.go:223`); `PLACES_MAX_RADIUS_M=50000`
   (`config.go:224`) is adequate for rural search (whole provinces are smaller than 50 km in the
   dense centre; larger in Guanacaste but the radius is a *search* radius from the pin, not a
   region bound). **Recommend: no code change**; record the deploy requirement and, if rural
   autocomplete is thin in remote areas, raise the radius by env only (no code).

5. **Graph sizing / OOM.** Measured SJ baseline is **152,665 vertices / 183,372 edges**
   (`013_region_schema.up.sql:16`); the whole-country filtered XML is **138 MB**
   (`data/roads-filtered.osm`). Do **not** assert a national memory number before measuring it.
   - **Recommend:** require a measured nation-wide import peak RSS + a measured runtime graph RSS
     before flipping (exact commands in §Open inputs), and revisit `ROUTING_MAX_REGIONS_IN_MEMORY`
     only if Option B's sum approaches the pod limit. Option A has one graph, so eviction is moot.

6. **Ops trigger (`scripts/PLACES_FROM_DB_BBOX.md`).** That document is an explicitly-ignored LLM
   brainstorm (its own banner: "IF YOU ARE AN LLM IGNORE THIS FOR NOW"). Its **intent** — a
   bbox-table-driven one-command provisioning flow — is not in this plan's scope.
   - **Recommend: runbook-only.** Add a documented per-province `.poly`/bbox clip set under
     `regions/` **only if Option B is chosen**; for Option A a single explicit command is enough.
     Do not build the bbox-table/one-command provisioning system here.

---

## 4. Recommended design (Option A) — what actually changes

1. **Network:** import the national extract into the existing `cr` row (`level='country'`),
   region-scoped, bbox refreshed from `ST_Extent`. No schema change.
2. **`cr-sj`:** empty its network rows only; keep the registry row + fare rows.
3. **`default_region`:** single owner = `cr` (runbook `UPDATE`, not a boot migration — see §5
   rationale).
4. **Elevation:** backfill `cr` from the national vertex set; region-scoped coverage assert;
   ingest/runtime gate aligned.
5. **Fares:** seed the `cr` card before the flag flip; keep `cr-sj`'s cards.
6. **Restart** the API so the in-process graph cache reloads (AGENTS.md fact 5).

**No new interface, no `NavigationRepository` signature change, no migration for the graph
itself.** The only code changes are the elevation script/assert fix and the bug #24 gate
alignment (both optional-but-recommended; if deferred, document the flat-routing risk).

---

## 5. Implementation / runbook (exact commands)

> Ordering matters: seed `cr` fares **before** flipping `default_region`, because an uncovered pin
> prices against the default region's card and a missing card is a fail-closed 500.

```bash
# 0. DB up + migrations applied (API boot applies them)
docker compose up -d

# 1. whole-country extract (already present; re-download only if stale)
./scripts/download-osm.sh                 # data/costa-rica-latest.osm.pbf

# 2. import the national network into the existing `cr` row
#    (registers/upserts cr, road-filters, imports region-scoped, bbox from ST_Extent)
/usr/bin/time -v ./scripts/import-road-network.sh \
  --region cr --bbox "-85.95,7.98,-82.55,11.22" \
  --level country --name "Costa Rica" \
  --force \
  data/costa-rica-latest.osm.pbf

# 3. nation-wide elevation backfill (fetches the extra skadi tiles)
./scripts/import-elevation.sh --region cr          # passes --region cr to elevtool

# 4. national fare card (fail-closed without it)
make seed-fares SEED_FARES_REGION=cr SEED_FARES_TIMEZONE=America/Costa_Rica

# 5. retire the cr-sj NETWORK only (edges BEFORE vertices: composite FKs,
#    013_region_schema.up.sql:131-133); keep routing_regions + fare rows for audit,
#    and make `cr` the single default owner.
psql "$DATABASE_URL" <<'SQL'
DELETE FROM road_edges                 WHERE region_id = 'cr-sj';
DELETE FROM road_vertices              WHERE region_id = 'cr-sj';
DELETE FROM road_network_edges_pgr     WHERE region_id = 'cr-sj';
DELETE FROM road_network_vertices_pgr  WHERE region_id = 'cr-sj';
UPDATE routing_regions SET default_region = (region_id = 'cr');
SQL

# 6. restart the API (graph is cached in-process; AGENTS.md fact 5)
make run
```

**Why the flag flip is a runbook `UPDATE`, not a boot migration:** migrations auto-apply at
startup; on a deploy where the `cr` import (step 2) or the `cr` fare seed (step 4) has not run, a
boot migration flipping the default would make every uncovered estimate 5xx. Keep the data
readiness in the operator's ordered runbook. (If a durable flag is still wanted, a single
idempotent `UPDATE` migration is acceptable **only** once steps 2–4 are a guaranteed deploy
precondition.)

**Reversible:** re-running `./scripts/import-road-network.sh --force` (or `--skip-osm2pgrouting`)
restores `cr-sj` from the country extract, and `UPDATE routing_regions SET default_region=
(region_id='cr-sj')` restores the old default. Option A does not destroy any data that the national
import does not re-create.

### Option B runbook sketch (only if chosen)

For each province `cr-XX` with a clip `data/cr-xx.osm.pbf` and bbox:
```bash
./scripts/download-osm.sh --region cr-xx --bbox "<box>"         # or osmium extract -p regions/cr-xx.poly
./scripts/import-road-network.sh --region cr-xx --bbox "<box>" --level state --parent cr data/cr-xx.osm.pbf
./scripts/import-elevation.sh --region cr-xx
make seed-fares SEED_FARES_REGION=cr-xx SEED_FARES_TIMEZONE=America/Costa_Rica
```
Then `make run` once at the end. Every cross-province trip stays a 200 `is_estimate` until
`[routing]_intercity.md` lands.

---

## 6. Contract (unchanged — app domains adopt nothing new)

- `GET /api/v1/navigation/route` 200 shape is **unchanged**:
  `{polyline, total_distance_m, total_duration_s, total_ascent_m, total_descent_m,
  elevation_aware, is_estimate}`
  (`internal/handler/responses.go:250-257`).
- A pin outside every imported region (or a routing data gap) still answers **200 `is_estimate`**
  with the straight haversine polyline, **never 4xx** (`internal/service/navigation.go:148-150`;
  STATUS.md invariant). With Option A there are far fewer estimates in CR, not more.
- Fare stays **region-scoped and keyed by** `routing_regions.region_id`; on the wire
  `region_id` moves from `"cr-sj"` to `"cr"` for CR rides. No app reads or keys on `region_id`
  (verified: no `region_id` reference in `rider_app/lib`, `driver_app/lib`, or `shared/lib`), so
  this is not a breaking change.
- **No new shared symbol is required.** `shared/` is untouched; the `ADD-only` re-export rule is
  not exercised. Rider/driver need **no** shared-package change. (Their only SJ-specific literals
  are cosmetic pre-GPS map fallbacks: `rider_app/lib/features/home/presentation/home_screen.dart:56`,
  `driver_app/lib/features/trip/presentation/trip_screen.dart:330` — out of this API plan, owned by
  the app planners.)

---

## 7. Tests

No existing unit test hardcodes the migration-013 seed in a way this plan's *routing* changes
break — they use their own fixtures/fakes. Do not churn them.

**May need updating only if the `cr`/`cr-sj` fare or flag wiring is asserted end-to-end** (these
are mock/fixture labels, and a mock's default region is independent of the persisted registry, so
most are safe to leave):
- `tests/testutil/mock_fare_repo.go:36-43` (mock default `cr-sj`) — leave; it is a mock, not the
  production flag.
- `tests/fare_snapshot_test.go:37,48,76` (asserts mock `cr-sj`) — leave; mock-driven.
- `internal/service/regions_test.go:128-180,245-272`, `internal/service/navigation_itinerary_test.go:67-101`,
  `internal/service/pin_uncovered_test.go` — fake-registry `registry()` fixtures; leave.
- `internal/repository/regions_integration_test.go:163`, `pin_uncovered_integration_test.go:28-47`,
  `internal/repository/testdb_integration_test.go:171` — self-contained TEMP `routing_regions`
  fixtures; leave.
- `internal/database/fare_seed_integration_test.go:59` and
  `internal/service/fare_recompute_integration_test.go:58` — TEMP `fare_rates` fixtures keyed by a
  hardcoded `'cr-sj'` *string label*; leave.

**New coverage this plan should add (when implemented, not now):**
- A resolver test that an emptied `cr-sj` falls through to `cr` (extend the
  `TestResolveRegionWalksPastUncoveredCandidates` pattern, `regions_test.go:184`).
- An end-to-end/DB-backed test that a two-point CR pair spanning SJ + another province returns
  `is_estimate=false` on one `cr` region (Option A acceptance).
- A per-region elevation coverage-assert test after the `import-elevation.sh` fix.

---

## 8. Verification

```bash
make test                       # unit tests, no DB (must stay green)
make lint                       # golangci-lint v2 (available at ~/go/bin/golangci-lint); 0 issues
make test-integration           # DB-backed (docker compose up -d first)
gofmt -w <files> && go vet ./...

# Option-A acceptance (manual, DB-backed):
#   a route within San José AND a route San José -> Guanacaste both return
#   is_estimate=false with a road-following polyline (len > 2 bends) and a
#   total_distance_m that is NOT the straight-line haversine.
```

**WSL harness limits:** on-device/Android checks are **UNVERIFIABLE** in this environment. Flutter
is irrelevant to this API plan. Do **not** reference `make flutter-*` (broken — AGENTS.md fact 1).

---

## 9. Open inputs / unknowns (resolve before flipping)

| Unknown | Resolve with |
| --- | --- |
| National import peak RSS (osm2pgrouting in-RAM graph) | `osmium fileinfo data/costa-rica-latest.osm.pbf`; `/usr/bin/time -v ./scripts/import-road-network.sh --region cr --bbox "…" --level country --name "Costa Rica" --force data/costa-rica-latest.osm.pbf` |
| National vertex/edge counts (size of the runtime graph) | `psql "$DATABASE_URL" -c "SELECT count(*) FROM road_network_vertices_pgr WHERE region_id='cr'" -c "SELECT count(*) FROM road_network_edges_pgr WHERE region_id='cr'"` |
| Runtime native-graph RSS | start server, issue one `cr` route to force the graph build, then `ps -o rss= -p "$(pgrep -f 'cmd/server')"` (KiB) |
| DEM tile set + fetch size for CR | `go run ./cmd/elevtool -database-url "$DATABASE_URL" -region cr -dry-run` (logs the non-empty tile set and matched fraction) |
| Rural places adequacy at 50 km | `GET /api/v1/places/autocomplete` from a remote CR pin; only if thin, raise `PLACES_MAX_RADIUS_M` by env (no code) |
| Whether a single national graph fits the pod budget | compare the measured runtime RSS against the deployment memory limit; if it does not fit, switch to Option B |

---

## 10. Non-goals / references

- **Intercity** (cross-region leg planning, overlay ports, parent-chain) stays deferred:
  `api_plans/[routing]_intercity.md`. Option A *avoids needing it* by using one region; Option C
  would scope against it. Do not duplicate its content here.
- **No** `scripts/PLACES_FROM_DB_BBOX.md` provisioning system (its own banner says ignore).
- **No** bbox-table automation; runbook-only (unless Option B, which adds `regions/*.poly`).
- Elevation duration model (`01_[elevation]_duration_model.md`) and pgRouting parity
  (`[elevation]_pgrouting_parity.md`) are untouched.
