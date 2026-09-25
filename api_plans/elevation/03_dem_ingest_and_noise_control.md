# Stage 03 — DEM ingest + noise control (real elevation data)

**Goal.** Put actual, trustworthy elevation onto the routing vertices, using **stdlib-only Go**
and an open DEM, and — just as importantly — justify why the noise control lives in the cost
model rather than in a smoothing pass.

Depends on: `02_elevation_column_and_repo_plumb.md` (the `elevation_m` /
`elevation_source` columns and the coverage gate).

## Context

> ⚠ **Two blockers found by review and fixed here (`REVIEW.md` §1.1, §1.2, §1.6, §3.4,
> §4.1, §4.3).** The DEM URL in the first draft **404s** — the correct path is
> `skadi/{N|S}{LL}/{tile}.hgt.gz`, and the payload is **gzipped**. The tile list was also wrong:
> the bbox needs **six** candidate tiles and the one the first draft included
> (`N08W085`) contains **zero** vertices while `N08W084` (7 vertices) was missing. The
> `short − long` calibration estimator is **deleted** — it measures exactly 1.00× on real data
> and carries no signal.

**Read (nothing else):**

- `api_plans/elevation/README.md` — the verified-facts table (edge-length distribution is the
  input to this stage's whole argument) and invariant 4 (degrade to flat, never to garbage).
- `api_plans/elevation/01_directional_cost_model.md` — the `DeadbandM` / `MaxGrade` semantics.
  This stage does not change them; it explains why they are load-bearing.
- `api_plans/elevation/02_elevation_column_and_repo_plumb.md` — the columns being written, and
  **Part 3a, the NULL-endpoint edge rule** (the tool must not create that state, but the
  backfill's unmatched rows are exactly how it arises).
- `internal/database/migrations/015_vertex_elevation.up.sql` — the exact column names/types.
- `Makefile:1-56` — target style, `DATABASE_URL` construction, `.PHONY` list.
- `scripts/import-road-network.sh:117-119` — the `psql_run` helper (and why this stage does
  **not** add SQL to that heredoc).

**Write:**

- `cmd/elevtool/main.go` *(new — the DEM sampler + DB writer)*
- `cmd/elevtool/hgt.go` *(new — SRTM `.hgt` reader, separable and unit-testable)*
- `cmd/elevtool/hgt_test.go` *(new)*
- `scripts/import-elevation.sh` *(new)*
- `Makefile` — `import-elevation` target + `.PHONY` entry.
- `api_plans/elevation/03_dem_ingest_and_noise_control.md` — this file, updated with the
  runbook and the measured diagnostics.

**Do NOT touch:** `internal/routing/*` (stage 01 owns the noise control), `internal/config/*`
and `internal/repository/*` (stage 02), `internal/database/migrations/*` (015 already exists;
this stage adds no migration), `scripts/import-road-network.sh` (read-only here),
`docker-compose.yml` (no volume mount is needed — the tool fetches over HTTPS), the Flutter apps.

**Needs a DB?** Yes — it writes 150k rows.

## Problem

Stage 02's coverage gate will (correctly) refuse to route with elevation while
`elevation_m` is all-NULL. So the feature is inert until real data lands. The naive way to get
that data — sample a DEM per vertex — is **actively harmful on this network**, and the reason
is a measured property of the network itself, not a general DEM caveat:

> The SJ import has a **median edge length of 64.4 m**; **30.5 % of its edges are shorter than
> 40 m** and **15.2 % shorter than 20 m**. SRTM 1-arcsec has a **~30.9 m posting**. So for
> roughly a third of the network, **one edge is shorter than one DEM cell**: consecutive
> vertices sample neighbouring-but-different DEM posts, and the difference between two
> independent ~5 m vertical errors is read by the cost model as a real 10–25 % grade.

Feeding that in without damping produces routes that chase DEM noise — a
"elevation-aware" router that detours onto arterials because a bridge deck samples two metres
lower than the road beside it. Stage 01's `DeadbandM` and `MaxGrade` exist for exactly this,
and **this stage's job is to show they are the right (and only) filter for v1**, and to provide
the diagnostics that prove it.

## Current State (verified 2026-09-25)

- `road_network_vertices_pgr` = 152,665 rows, bbox lat `8.9884899 … 10.2369185`,
  lng `−84.5361388 … −83.3904684` (province clip, `download-osm.sh`). Edge-length stats and
  the migration inventory are in the series README's verified-facts table.
- **Six 1° tiles are candidates for that bbox, and five of them carry vertices.**
  A 1° tile spans lat `N…N+1` / lng `W…W+1`; the bbox straddles 9°N and 10°N and −84°/−83°,
  so the candidate set is 3 × 2. Assigning all 152,665 live vertices to their own tile:

  | tile | vertices |
  |---|---|
  | `N08W084` | **7** |
  | `N09W085` | 79,731 |
  | `N09W084` | 38,141 |
  | `N10W085` | 31,690 |
  | `N10W084` | 3,096 |
  | `N08W085` | **0** |

  The first draft of this plan listed `N08W085` (zero vertices) and omitted `N08W084`
  (7 vertices), which would have produced 7 unmatched vertices and 12 half-elevation edges —
  failing this stage's own "0 unmatched" and "query 5 = 0" assertions. **Tile selection must
  be driven by the vertex set, not by the bbox corners**, and the unit test must cover a
  zero-vertex tile (see Tests). Re-derive this table with the query in Tests; do not trust it
  if the data has been re-imported.
- `elevation_m` is NULL on all 152,665 rows; `elevation_source` likewise.
- The image **has** `postgis_raster 3.5.2` (created by `scripts/init-pgrouting.sh:24`), so the
  "load a GeoTIFF and `ST_Value` it" path is technically available — see *Alternatives* for
  why this stage does not take it.
- No Go module beyond the API's own is used anywhere in the repo; `go.mod` has no `godotenv`,
  no CLI framework, and adding one for a single-shot ops tool is not worth it.
- `scripts/import-road-network.sh:318` truncates both routing tables on a forced import, so
  **every import wipes elevation** (stage 02, Part 5). Ordering is a runbook problem, not a
  code problem, until plan 06.

## Solution

### Part 1 — DEM choice: AWS Terrain Tiles `skadi` 1-arcsec, anonymous

| Option | Verdict |
|---|---|
| **`https://elevation-tiles-prod.s3.amazonaws.com/skadi/{N\|S}{LL}/{tile}.hgt.gz`** — 1 arc-sec (~30 m), EGM96 orthometric, **anonymous HTTPS**, gzip-compressed raw 16-bit, no key, no GDAL | **Chosen.** Verified live: `skadi/N09/N09W085.hgt.gz` → `200 application/x-gzip`, 7,798,473 bytes, decompressing to exactly `3601 × 3601 × 2 = 25,934,402` bytes. Needs `compress/gzip` from stdlib — no third-party dependency. |
| `s3://elevation-tiles-prod/srtmgl1/…` | **DOES NOT EXIST.** The bucket's prefixes are `docs/ geotiff/ lib/ logs/ normal/ skadi/ terrarium/ v2/` — there is no `srtmgl1`. Every such URL 404s with a ~290-byte XML body. The first draft of this plan chose it; that was the single most expensive error in the series, and it is corrected here. |
| `s3://elevation-tiles-prod/geotiff/` (Copernicus GLO-30, 2010–2015) | Better quality, but Go's stdlib cannot read GeoTIFF. Requires GDAL/`gdal_translate`, which is not guaranteed in this harness. Recorded as the scale path, not built. |
| `s3://elevation-tiles-prod/terrarium/{z}/{x}/{y}.png` | Same data, PNG-encoded — needs an image decoder and z/x/y tiling math for no benefit over `.hgt`. |
| `skadi/{tile}.hgt` (uncompressed) | 404 — the bucket serves `.gz` only. |
| open-elevation / opentopography APIs | Network dependency in a hot path, rate limits, no. |
| OSM `ele=*` node tags | Only a few percent of vertices carry one. Useless as a primary source. |
| PostGIS raster + `ST_Value` | Available (extension present) but puts a raster file in the container and a raster join in the graph-build path. Deferred — see *Alternatives*. |

Source URL form:
`https://elevation-tiles-prod.s3.amazonaws.com/skadi/N09/N09W085.hgt.gz`
(one gzipped 1-arcsec tile ≈ 7.8 MB, 25.9 MB in memory; the five tiles above are ~39 MB of
download). `elevation_source` is written as **`skadi:<tile>`** (e.g. `skadi:N09W085`).

### Part 2 — `cmd/elevtool/hgt.go`: the gzipped `.hgt` reader

The payload is gzip-compressed raw big-endian `int16`, row-major, `3601 × 3601` for 1-arcsec,
`-32768` = void. **Row 0 is the NORTHERNMOST row** and column 0 the westernmost — getting this
backwards silently mirrors your city north↔south, which is the single most likely bug in this
stage after the URL itself.

```go
// Tile is one 1-degree SRTMGL1 (skadi) .hgt tile in memory.
type Tile struct {
    MinLat, MinLng float64 // SW corner, degrees
    Rows, Cols     int
    Data           []int16
    Name           string // e.g. "N09W085" — recorded as elevation_source
}

// ParseHGT decompresses a .hgt.gz payload and validates its dimensions.
func ParseHGT(name string, gzipped []byte) (*Tile, error)   // 3601² = 1 arc-sec, 1201² = 3 arc-sec
func (t *Tile) At(row, col int) (int16, bool)                // false on void / OOB
func (t *Tile) Sample(lat, lng float64) (float64, bool)     // bilinear, false on void/OOB
```

- Name → corner: `N09W085` ⇒ `MinLat=9`, `MinLng=-85`; `S01E006` ⇒ `MinLat=-1`, `MinLng=6`.
  Reject anything else. The `skadi` directory segment (`N09`, `S01`) must be derived from the
  name, not parsed independently — two sources of truth for the same tile is a bug factory.
- Dimensions from the **decompressed** length: `1201` ⇒ 3-arcsec, `3601` ⇒ 1-arcsec
  (`25,934,402` bytes for 1-arcsec). Reject other sizes explicitly rather than guessing.
- `Sample`: `rowF = (t.MinLat+1 - lat) * (Rows-1)`, `colF = (lng - t.MinLng) * (Cols-1)`;
  clamp to `[0, Rows-1]`; bilinear over the four neighbours; **any void neighbour ⇒ not ok**
  (do not silently average a void into a real number). Outside the tile ⇒ not ok.
- `hgt_test.go`: a synthetic 3×3 gzipped tile with known values proves the gzip round-trip, the
  north-up row order, the corner names, the bilinear weights, void handling, and the size
  rejection. No DB, no network.
- `tiles_test.go` — tile selection as a **pure function** `tileNameFor(lat, lng) string` over a
  synthetic vertex list, so the tile-set logic is testable with no DB and no network. Cases:
  the four interior vertices and the exact 7-vertex `N08W084` corner cluster both resolve to
  `N08W084`; a vertex set with **no** vertex in `N08W085` produces a fetch set of **five**,
  not six. This is the regression test for the §1.2 blocker: the bug was "compute the fetch
  set from the bbox instead of from the vertices", and a bbox-derived set cannot be caught by
  an end-to-end test that happens to pass on the current data.

### Part 3 — `cmd/elevtool/main.go`: sample the vertices, write with `COPY`

```
elevtool -database-url ... -bbox auto -dem-dir data/dem -source skadi [-fetch] [-dry-run]
         [-region cr-sj] [-threads 0]
```

1. **Determine the work set.** `SELECT id, ST_Y(the_geom) AS lat, ST_X(the_geom) AS lng FROM
   road_network_vertices_pgr` — scoped to `-region` when that column exists. Probe
   `information_schema.columns` for `region_id`; if the flag is passed and the column is
   absent, **error out** (do not silently sample every region and overwrite).
2. **Compute the tile set from the vertex set**, not from the bbox corners: bucket every vertex
   by its own 1° tile, and fetch only the tiles that actually received a vertex. The candidate
   set is the bbox's 3 × 2 block; the fetched set is the non-empty subset (five of six here).
   Load them one at a time (25.9 MB each, so peak memory ≈ one tile + the vertex list). For each
   vertex, find its tile and sample.
3. **`-fetch`** downloads a missing tile over HTTPS into `-dem-dir` (cache the `.hgt.gz`;
   decompress on read) and skips it if already present. A tile that 404s is reported, not
   fatal — but note that **every URL in the `skadi` layout must be validated end-to-end before
   this stage is implementable**, because a wrong prefix produces a 290-byte XML body saved
   under a `.hgt.gz` name, which the size check then rejects with a confusing error. The fix
   for that specific confusion is a content-type/size check before caching, not a bigger error
   message.
4. **Write with `COPY`, inside a transaction.** `pq.CopyIn("road_network_vertices_pgr", "id",
   "elevation_m", "elevation_source")`. Plan 03 already learned the hard way that
   `pq.CopyIn` **must** run inside a transaction (`api_plans/03` gate notes) — reuse that.
   Only matched vertices are written, so a void or missing-tile vertex keeps its `NULL` and is
   excluded from the coverage count. `elevation_source` = `skadi:<tile>` **per vertex** — per
   tile is the honest granularity and makes a mixed-vintage import visible in one query.
5. **`-dry-run`** prints: tile list, per-tile vertex counts, matched/unmatched counts, and the
   elevation range — without opening a write transaction. This is the mode to use first, every
   time.
6. Exit non-zero if the matched fraction is below `-min-coverage` (default 0.98) — the same
   spirit as stage 02's repo gate, so a broken DEM cannot half-apply.

Deliberately **not** in this tool: smoothing, resampling, dedup, region registration, importing
the OSM network. It samples a DEM onto whatever vertices exist. That is the whole job, and a
tool that does one thing is a tool a fresh context can be trusted with.

### Part 4 — Noise control: why the cost model IS the filter

Order of operations, and what each step defends against:

| Artifact | Defense | Where |
|---|---|---|
| DEM vertical error (SRTM-class LE90 ≈ 5 m; worse in mountains) | `DeadbandM` | engine, stage 01 |
| Error amplified across a sub-cell edge (20 m edge × 3 m → 15 % grade) | `MaxGrade` = 0.15 clamps it | engine, stage 01 |
| A single pathological edge (a 50 % ramp artifact) | `MaxGrade` clamp | engine, stage 01 |
| Real but absurd road grades (a 30 % driveway) | `MaxGrade` clamp | engine, stage 01 |
| Spatially-correlated bias (systematic tilt across the region) | **Not** defended — see below | — |

> **Measured on real data (`REVIEW.md` §4.1, `skadi` DEM, 183,366 sampled edges, provisional
> defaults):** the deadband at 3 m touches **59.5 %** of edges and the cap touches **5.0 %** —
> so the deadband does almost all the work, and the class it does *not* touch is the noisy one:
> **25.1 % of edges carry 3–10 m of |Δz| with a mean of 5.43 m**, which on a 30 m edge is an
> ~18 % grade. The deadband does nothing to that class, the clamp pins it at 15 %, and the cost
> function then prices it as a full 22.5 % surcharge — converting random noise into a
> **systematic uphill tax**, which is the precise failure mode this section claims to prevent.
>
> **Therefore the provisional `DeadbandM` of 3 m is wrong for this DEM, and 5 m is not enough
> either** (the first draft of this plan recommended 5.0; that is asserted, not derived, and it
> leaves the bulk of the 5.43 m-mean class untouched). The honest statement is: **the deadband
> is the dominant noise control and its value is unknown until it is swept.** Stage 04 runs the
> sweep. Do not defend 3 m.

**Deadband is per-edge and therefore still an additive edge cost** — `dz′ = 0` when
`|dz| ≤ DeadbandM` is a function of the edge alone, so A\* optimality is unaffected. This is
the reason the fix belongs in the cost function and not in a pre-pass: a smoothing pass would
have to be re-derived, re-tuned, and re-validated every time the DEM or the network changes,
and it would make the engine's behaviour depend on a data artefact nobody can inspect at
request time.

### Part 4a — Deleting the `short − long` calibration estimator

The first draft of this stage proposed calibrating `DeadbandM` from the mean |grade| on short
edges minus the mean |grade| on long edges, reasoning that sub-cell edges should show more
grade. **Measured, that difference is exactly 1.00×** (5.197 % vs 5.197 % over 55,906 short and
127,460 long edges) — the estimator carries no signal, and the plan's own decision rule ("if the
difference is small, lower the deadband") would have driven the default in the wrong direction.
Its premise was also wrong: an edge shorter than a DEM cell does **not** automatically land on a
different post, and the network's edges are not randomly placed relative to the DEM grid.

**Replacement estimator (used in stage 04, designed here):** isolate sampling noise by
comparing grade against **DEM cell-boundary straddling**, not against edge length.

```sql
-- An edge that crosses a 1-arcsec cell boundary in BOTH axes is most exposed to
-- independent sampling error; one that stays inside a single cell is not.
-- Grade excess on the straddling set, after removing the effect of true terrain,
-- is the noise estimate. If the two sets are indistinguishable, the DEM is
-- resolving this network well and the deadband should stay SMALL.
```

Pair it with a **direct, assumption-free check that is better than either**: take known-flat
urban arterials (a hand-picked handful of straight city blocks with no relief) and look at the
**spread** of `Δz` along them. A flat street should show `|Δz| ≈ 0`; whatever it actually shows
is the noise floor, and `DeadbandM` must sit above it. This is three streets and ten minutes of
work, and it is a measurement rather than a proxy. **Do it before stage 04 tunes anything.**

**Known limitation, stated rather than hidden: constant datum bias does not matter, and
grade separation does.** A uniform vertical offset across a whole region cancels in every
`dz`, so the EGM96-vs-EGM2008 question is irrelevant to route choice. What *does* matter:

- **Mixing two DEMs inside one region** creates a real step. `elevation_source` exists to make
  that queryable (`GROUP BY elevation_source`), and the tool's per-tile source tag makes it
  visible per row.
- **Bridges and tunnels are invisible.** A road crossing over itself at grade gets the same
  DEM value at both levels, so the router believes the crossing is flat. This is unfixable
  without OSM bridge/tunnel tags or a level attribute — out of scope, and it is a *fair*
  failure (a flat reading on a bridge is not a nonsense route).
- **Sub-cell sampling aliases.** Bilinear interpolation at 30 m posting sampled at 20 m edge
  spacing is under-sampled by construction. The deadband is the mitigation; the residual is
  what stage 04 measures.

**Deferred to stage 04, with the recipe so it is actionable:** if the diagnostics below show
residual noise, the next filter is a **k-hop moving average** over each vertex's graph
neighbours (`ele[v] ← mean(ele[u] for u in N(v))`, k = 2–3, one pass, then freeze) computed
**once at graph build** — not in the tool, not per request. It must be measured against the
flat-invariance check, not assumed to help.

### Part 5 — Diagnostics (run these; paste the output into the MEASURED block)

```sql
-- 1. coverage: expect ~100% minus voids/missing tiles. NOT near zero.
SELECT count(*) AS total, count(elevation_m) AS covered,
       round(100.0*count(elevation_m)/count(*), 2) AS pct
FROM road_network_vertices_pgr;

-- 2. provenance: MUST be a single row for a clean single-DEM import.
SELECT elevation_source, count(*) FROM road_network_vertices_pgr
WHERE elevation_m IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;

-- 3. range sanity: the province clip reaches Cerro de la Muerte (9.5497, -83.7699,
--    3,491 m), so a max in the low thousands is expected. A max near 0 means the
--    DEM never loaded; a min near 0 is normal (coastal plain).
SELECT min(elevation_m), max(elevation_m), avg(elevation_m) FROM road_network_vertices_pgr;

-- 4. THE noise check: grade histogram over all edges, 2% buckets to 30%.
SELECT round(width_bucket(100.0*abs(t.elevation_m-s.elevation_m)/e.cost, 0, 30, 15)*2.0, 1)
         AS grade_pct, count(*)
FROM road_network_edges_pgr e
JOIN road_network_vertices_pgr s ON s.id = e.source
JOIN road_network_vertices_pgr t ON t.id = e.target
WHERE e.cost > 0 AND s.elevation_m IS NOT NULL AND t.elevation_m IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- 5. no half-backfilled edges (a cliff at every un-matched vertex)
SELECT count(*) FROM road_network_edges_pgr e
JOIN road_network_vertices_pgr s ON s.id = e.source
JOIN road_network_vertices_pgr t ON t.id = e.target
WHERE (s.elevation_m IS NULL) <> (t.elevation_m IS NULL);
-- expect 0. Anything else means the write was partial -- roll back and re-run.
```

**Reading query 4 — the pass/fail shape to look for.** A real urban network skewed steep has a
long tail; a *noisy* one has a fat, symmetric spike in the 10–20 % buckets concentrated on
short edges. The decisive check is the cross-tab of grade against edge length:

```sql
SELECT CASE WHEN e.cost < 40 THEN 'short(<40m)' ELSE 'long' END AS len_bucket,
       round(avg(100.0*abs(t.elevation_m-s.elevation_m)/e.cost))::int AS avg_grade_pct,
       count(*)
FROM road_network_edges_pgr e
JOIN road_network_vertices_pgr s ON s.id = e.source
JOIN road_network_vertices_pgr t ON t.id = e.target
WHERE e.cost > 0 AND s.elevation_m IS NOT NULL AND t.elevation_m IS NOT NULL
GROUP BY 1;
```

**The `short − long` comparison is retained in the query set as a regression tripwire, not as a
calibration input.** It is still a cheap check that the DEM changed underneath you (a large
sudden shift means the source moved, not that the noise floor moved), and it is one line of
SQL. But the *interpretation* is fixed: measured on real `skadi` data it is **1.00×**
(5.197 % vs 5.197 % over 55,906 short and 127,460 long edges), so it is **not** a noise
estimate, and it must never be used to move `DeadbandM` up or down. The estimator that replaced
it is in Part 4a. **Record both numbers, interpret as a tripwire only.**

### Part 6 — Runbook (this ordering is load-bearing)

```bash
docker compose up -d
make import-osm              # elevation_m is NOT written by the importer at all (stage 02 Part 5)
go run ./cmd/elevtool -dry-run -fetch      # inspect tiles + coverage FIRST
make import-elevation                      # writes elevation_m + elevation_source
make run                     # RESTART: the native graph is cached in-process
```

The restart is not optional (AGENTS.md env fact 5): the graph built at boot is the one that
will be used, and it holds `EleM` values loaded before the backfill. Until plan 06 makes the
graph import-fresh, **import → elevation → restart** is the only correct sequence. Put this
three-line order at the top of the script too, so it is impossible to run them apart.

## Tests to add

- `cmd/elevtool/hgt_test.go` (no DB, no network): corner-name parsing for `N09W085` / `S01E006`
  / `W` hemisphere; size validation rejecting a 2-byte file; **north-up row order** (a tile
  whose row 0 is 1000 and row 3600 is 0 must sample the northern point as 1000); bilinear
  weights at a cell centre and at a corner; void (`-32768`) anywhere in the 2×2 ⇒ not ok;
  a point outside the tile ⇒ not ok.
- `cmd/elevtool/main_test.go` (no DB): tile-set computation from a bbox — assert that the SJ
  bbox yields exactly `N08W085, N09W085, N09W084, N10W085, N10W084` and no others (this is the
  test that catches a missing tile at a bbox edge, which silently NULLs a whole strip of
  vertices).
- No DB-backed test for the `COPY` path beyond `-dry-run`; the write is 150k upserts of a
  nullable column with a coverage precondition, and the post-write diagnostics in Part 5 are
  the real verification. If a `-dry-run`-shaped unit seam appears while implementing, test it —
  but do not build a fake-DB harness for this.

## Verification

1. `go test -count=1 ./cmd/elevtool/ ./internal/routing/` green (no DB needed for either).
2. `make test` green.
3. `go run ./cmd/elevtool -dry-run -fetch` → **six tiles in the candidate set, five fetched**
   (all of `N08W084 N09W084 N09W085 N10W084 N10W085`), ~152,665 matched, **0 unmatched**
   (or an explained list), and an elevation range consistent with query 3.
4. `make import-elevation`, then the diagnostic queries of Part 5, pasted into MEASURED.
   Query 2 = one source row (`skadi:…`); query 5 = 0.
5. **`make import-elevation` must end in a coverage assertion.** Because the importer never
   writes `elevation_m`, a routine `make import-osm` returns the feature to flat routing
   silently. The script therefore finishes with the coverage query and **exits non-zero when
   coverage is below the configured gate**; the post-import state is "import, then elevation,
   then restart", and the runbook says so in those three words. This assertion is the only
   guard, so it is part of this stage's verification, not a nicety.
6. `make run` (restart), then a route curl → HTTP 200 with `ROUTING_ELEVATION=off` produces a
   polyline **identical** to the pre-stage-02 capture (proves the data landed without changing
   default behaviour), and the boot log shows the single combined engine/elevation line from
   stage 02 Part 4.
7. `gofmt -w cmd/elevtool/*.go && go vet ./cmd/elevtool/`.
8. Confirm `data/dem` is git-ignored (**gzip already reduces the five tiles to ~39 MB**; the
   ~130 MB figure in the first draft assumed uncompressed `.hgt`) and that
   `scripts/import-elevation.sh` is executable (`chmod +x`), matching
   `scripts/import-road-network.sh`.

## MEASURED

_(to fill: the five diagnostic queries, the `-dry-run` output, the `short − long` tripwire
ratio, the known-flat-street `Δz` spread, and the measured size of `data/dem`. Stage 04 consumes
all of it.)_

## Decisions Recorded

- **SRTM1-class `skadi` `.hgt.gz` over every alternative.** Open, keyless, parseable with
  stdlib (`compress/gzip` + `encoding/binary`), ~30 m. Quality (a 2000-era radar mission,
  5–9 m vertical) is adequate *because* the cost model damps per-edge error — and Part 4a
  quantifies exactly how much it does not damp, which is the input to stage 04's sweep. A
  better DEM is a stage-04/05 improvement, not a v1 requirement.
- **Noise control lives in the cost function (deadband + grade cap), not in a smoothing
  pre-pass.** Deadband is per-edge, so it keeps the cost additive and A\* provably correct; a
  pre-pass is invisible at request time and must be re-validated on every data change.
  k-hop averaging is named, formulated, and deferred to stage 04 with a measurement gate.
- **Per-vertex, not per-tile, `elevation_source`.** A mixed-vintage import becomes a one-query
  `GROUP BY` instead of an archaeology project.
- **Unmatched vertices stay NULL.** Coalescing to 0 would fabricate a cliff on every
  un-matched edge and would defeat stage 02's coverage gate.
- **No smoothing in `cmd/elevtool`.** The tool's contract is "sample this DEM onto these
  vertices" and nothing else, so it stays trustworthy and stage-04 tuning lives in one place.
- **Runbook order import → elevation → restart is mandatory** until plan 06.

## Alternatives & Future

- **PostGIS raster + `ST_Value` (Track B).** The extension is already installed, so this is
  viable and it scales to whole-country DEMs without 130 MB of tile fetching. Deferred because
  it needs the GeoTIFF inside the container (a `docker-compose` volume mount) and puts a raster
  join in the graph-build path per region. Revisit when a second, non-SJ region lands — which
  is plan 06's trigger. Record that trigger in plan 06.
- **Copernicus GLO-30** via `gdal_translate` → GeoTIFF → Track B. Better absolute accuracy and
  a 2010–2015 vintage; blocked on GDAL availability in this harness. The single highest-value
  upgrade if it ever becomes available, because the deadband could then shrink.
- **Tenant of the DEM as a per-region `routing_terrain` table** (region → source, resolution,
  acquisition date) instead of a per-vertex string. Better for many regions; the string is
  adequate for one and is what plan 04/05/06 can migrate to later.
- **Elevation on edges** — rejected in stage 02, restated here: it duplicates a derivable
  quantity into a second table and creates a backfill-consistency problem for no gain.
- **Real-time elevation at snap time** — no. Two pins per request is a rounding error; the
  whole network's elevations matter, not the pins'.
- **Landmark `DO NOT`**: do **not** re-run migration 009, do **not** wire
  `sample_elevation()`, and do **not** resurrect `road_edges.cost_elev`. `sample_elevation`
  is a placeholder that returns `0` (`009:2-8`) and its `UPDATE`s executed at migration time
  against an empty `road_vertices` (verified: 152,665 rows, 0 non-null). It is a landmine that
  looks like a working feature.

## Files to Modify

- `cmd/elevtool/main.go` *(new)* — tile selection, vertex fetch, `COPY` write, `-dry-run`.
- `cmd/elevtool/hgt.go` *(new)* — `Tile`, `ParseHGT`, `At`, `Sample`.
- `cmd/elevtool/hgt_test.go` + `main_test.go` *(new)*.
- `scripts/import-elevation.sh` *(new, `chmod +x`)* — `DATABASE_URL` from the same env vars as
  the Makefile, the three-line runbook in a comment header, delegates to `go run ./cmd/elevtool`.
- `Makefile` — `import-elevation` target + `.PHONY` entry.
- `.gitignore` — `data/dem/` if not already covered by a `data/` rule.
