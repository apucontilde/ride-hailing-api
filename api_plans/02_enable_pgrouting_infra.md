# Plan: Enable pgRouting infrastructure (image, init, migrations)

Making `pgRouting` **available** in the dev DB so downstream plans can swap the engine. This
plan is environment/infra only — **no Go code changes**; the API keeps using the native
engine (`ROUTING_ENGINE` stays `native`; plan 03 flips it after a benchmark gate).

## Problem

- The DB image `postgis/postgis:16-3.4-alpine` ships no pgRouting — `CREATE EXTENSION
  pgrouting` errors at first boot (AGENTS.md env fact 3). Migration 011 even ships a
  **stub** `public.pgr_dijkstra(text,bigint,bigint,boolean)` that only returns ≤2 vertices.
- A naive image swap is NOT enough: the stub shadows the real function, and existing volumes
  (which record migration 011 as applied) never re-run a rewritten 011.

## Current State (verified)

- `docker-compose.yml:5` — `image: postgis/postgis:16-3.4-alpine`, mount
  `./scripts/init-pgrouting.sh:/docker-entrypoint-initdb.d/init-pgrouting.sh:15`, ports
  5432:5432, healthcheck `pg_isready` (`docker-compose.yml:17`).
- `scripts/init-pgrouting.sh` — creates `postgis`, `postgis_raster`, `postgis_topology`,
  `fuzzystrmatch`, `pgrouting` (`init-pgrouting.sh:5–9`). Runs **only on first boot of an
  empty volume** (docker-entrypoint-initdb.d semantics); on an existing volume it never runs.
- **init-pgrouting.sh is a SHELL script** — do NOT `psql -f` it (that feeds `#!/bin/sh` to
  psql as SQL). Manual re-run: `docker exec -i ride-hailing-db sh -s < scripts/init-pgrouting.sh`
  (the bind-mount path is read-only; container env supplies POSTGRES_USER/POSTGRES_DB).
- **`ALTER EXTENSION ... UPDATE` has no `IF EXISTS` form** (implementation hit
  `pq: syntax error` → guard each UPDATE in a DO block — see Part 3).
- **`ls | sort -V` on Debian's `/usr/share/postgresql/` must filter numeric dirs** or it
  picks up the stray `postgresql.conf.sample.dpkg` file (`ls | grep -E '^[0-9]+$'`).
- Migrations run at **server boot** in `internal/database/migrate.go`; `schema_migrations`
  records each version and skips already-applied ones (`migrate.go:38–48` — so rewriting
  `011` has **zero effect on any volume that already ran it**; the rewrite only governs
  fresh DBs).
- `internal/database/migrations/011_create_routing.up.sql` — creates the two pgr tables +
  GIST index + btree source/target indexes + a **demo NYC seed** (vertices id 1/2 at
  40.71,-74.0 / 40.758,-73.9855 + edge id 100 cost 10000, `011:26–36`) + the stub function
  (`011:38–86`). The demo seed is dangerous: on a DB with no real import, any KNN snap lands
  on NYC (plan 02's old verification would pass `total_distance_m > 0` with a *New York*
  route), and `import-road-network.sh:184` sees `COUNT(*) = 1 > 0` so a plain `make
  import-osm` **skips the real import**.
- `pgrouting/pgrouting:16-3.5-4.0` exists on Docker Hub (PG16 + PostGIS 3.5.2 +
  pgRouting 4.0.1, Debian bullseye; source `pgRouting/docker-pgrouting`). Image layers show
  it **removes the postgis image's own `/docker-entrypoint-initdb.d/10_postgis.sh` hook** —
  so on the new image it is `scripts/init-pgrouting.sh` alone that creates PostGIS (that is
  also mandatory: pgRouting depends on PostGIS).

## Solution

### Part 1 — Image + init script

1. `docker-compose.yml` → `image: pgrouting/pgrouting:16-3.5-4.0`. **Keep** the initdb
   mount (it is what actually creates the extensions on a fresh volume). Ports/healthcheck/
   container name unchanged. Verify the tag exists first:
   `docker manifest inspect pgrouting/pgrouting:16-3.5-4.0`.
2. `scripts/init-pgrouting.sh` — make it robust AND runnable by hand against an existing
   DB (idempotent, `CREATE EXTENSION IF NOT EXISTS` for each). On the new Debian image the
   postgis packages provide `postgis`, `postgis_raster`, `postgis_topology` control files
   (the pgrouting image also ships `fuzzystrmatch`, verified — but guard anyway);
   **verify each** (`ls /usr/share/postgresql/16/extension/*.control` inside the container)
   and skip any extension whose control file is absent, so a fresh-volume init cannot abort
   (AGENTS.md env fact 6 analogue). Order postgis before pgrouting. Re-run it as a SCRIPT, as
   shown in the Current-State caveat:
   `docker exec -i ride-hailing-db sh -s < scripts/init-pgrouting.sh`.

### Part 2 — Rewrite migration 011 (fresh-DB only; existing volumes rely on 012)

In `internal/database/migrations/011_create_routing.up.sql`:

- **Remove the unconditional `DROP FUNCTION IF EXISTS public.pgr_dijkstra(text,bigint,bigint,boolean);`
  and the whole `CREATE OR REPLACE FUNCTION ... pgr_dijkstra ... END; $function$;` stub
  block**, replacing it with a guarded `DO $$` block that only creates the stub when pgRouting
  is NOT installed:
  ```sql
  DO $$
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgrouting') THEN
      -- [move the existing stub body here as a CREATE FUNCTION]
    END IF;
  END $$;
  ```
- **Guard the demo NYC seed the same way** (`WHEN no pgrouting extension`), so a fresh
  new-image DB never seeds rows that poison KNN routing (see Current State). Tables, GIST
  index, btree indexes stay unchanged.
- Do NOT expect this rewrite to change behaviour on any existing DB — see `schema_migrations`
  skip semantics above. 012 below is the mechanism for those.

### Part 3 — New migration 012 (one-time convergence for ALL existing volumes + fresh DBs)

`internal/database/migrations/012_enable_pgrouting.up.sql`. Because pgRouting's
`CREATE OR REPLACE` semantics leave an extension "owning" a replaced function, the safest
converging form is three unconditional statements (valid in every reachable state — stub
present, real function present, mixed, none): **do NOT** rely on `pg_proc.prosrc` sniffing;
drop/drop/create is idempotent and provably converges in this repo (nothing depends on
`pgr_*` functions — verified: only migration 011 references them):

```sql
-- 012_enable_pgrouting.up.sql

-- (1) purge the demo NYC seed — GEO-GUARDED. The "seed ids never collide"
--     assumption is FALSE: after ANY real import the pgr vertex ids are
--     SEQUENTIAL osm2pgrouting ids (verified live: SJ import fills 1..N), so
--     an id-range purge DELETES REAL ROWS. Purge only NYC-located rows (the
--     seed's two vertices are the only rows within 50 km of Downtown NYC);
--     a real import matches nothing. [rev-1 of 012 purged by id and deleted
--     two real SJ vertices + one edge on the dev volume — restored by hand;
--     `make import-osm-force` regenerates pristine data.]
DELETE FROM road_network_vertices_pgr
WHERE id IN (1, 2)
  AND the_geom IS NOT NULL
  AND ST_DWithin(the_geom::geography,
                 ST_SetSRID(ST_MakePoint(-74.006, 40.7128), 4326)::geography,
                 50000);
-- the demo edge connected the two seed vertices; purge it ONLY when those
-- seed vertices were actually present (removed above -> no 1/2 remain). A real
-- sequential import keeps ids 1,2 so this skips, leaving real edge 100 intact.
DELETE FROM road_network_edges_pgr
WHERE id = 100
  AND NOT EXISTS (SELECT 1 FROM road_network_vertices_pgr WHERE id IN (1, 2));

-- (2) converge to the REAL extension regardless of state:
--  - if the 011 stub (or an old image) is present, drop it;
--  - if a stale/healthy extension is present, drop+recreate it (restores members);
DROP FUNCTION IF EXISTS public.pgr_dijkstra(text, bigint, bigint, boolean);
DROP EXTENSION IF EXISTS pgrouting CASCADE;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pgrouting') THEN
    EXECUTE 'CREATE EXTENSION pgrouting';
  END IF;
END $$;

-- (3) postgis catalog vs new 3.5 libraries on a reused volume: align versions.
-- ALTER EXTENSION ... UPDATE has NO `IF EXISTS` keyword, so guard each in a DO block
-- (absent extension = no-op; cadence matches the other idempotent statements).
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis') THEN
    ALTER EXTENSION postgis UPDATE;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis_topology') THEN
    ALTER EXTENSION postgis_topology UPDATE;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis_raster') THEN
    ALTER EXTENSION postgis_raster UPDATE;
  END IF;
END $$;
```

Caveats the executor MUST understand:

- `migrate.go:56` sends the file as one multi-statement string; failure in a later statement
  does NOT roll back earlier ones, and the migration is only recorded on success. That is
  SAFE here (each statement is idempotent; a rerun converges). Do NOT wrap in an explicit
  `BEGIN;` — that would make a mid-failure atomic and brick the DB until manual cleanup.
- On a fresh DB with the NEW image: init script creates pgrouting → guarded 011 creates no
  stub → 012 drops nothing, recreates the extension (harmless), postgis UPDATE is a no-op.
- On a fresh DB with the OLD image (dev without the swap): `pg_available_extensions` has no
  pgrouting → 012's DO skips `CREATE EXTENSION` → the DB has NO `pgr_dijkstra` at all
  (stub removed). It still boots (no Go code calls `pgr_*` today) and routing stays on the
  native engine. Document this fail-degraded state in the import README.
- On an existing NEW-image volume (upgraded): OLD 011 already ran → stub present → 012 drops
  it, drops+recreates the extension → real function restored. This is the case 012 exists for.
- The stub's return shape (`seq,node,edge,cost,agg_cost`, 5 cols) differs from real
  pgRouting's 8-col output (see plan 03 §SQL) — the DO-block approach sidesteps any shape
  detection, which is why the three-liner is preferred.
- **pgr vertex ids are SEQUENTIAL osm2pgrouting ids, NOT OSM node ids.** Verified live on the
  SJ import: `road_network_vertices_pgr.id` fills `1..N` (post-012 restore: min 1 / max 152665 /
  count 152665; the similarly copied `road_vertices` (008) shows the same range). Everything
  downstream (plans 04, 06) MUST assume per-extract sequential ids: they collide across
  extracts, and nothing is stable across re-extracts of the same area. Migration 012 rev-1's
  demo-seed purge (`DELETE ... WHERE id IN (1,2)`) exploited this the WRONG way: on the dev
  volume it deleted two real SJ vertices + one real edge (id 100); geo-guarded (current) purge
  restores the intent. Full pristine graph = `make import-osm-force`.
- `CREATE EXTENSION pgrouting` requires **superuser**; in this compose setup `ridehail`
  (POSTGRES_USER, also the server's migration user via `config.go` env) IS the superuser by
  default, so migrations work without a `postgres` hop.

Dev-recommended path: `docker compose down -v` (fresh volume, wipes data + extensions) then
`docker compose up -d` — initdb runs the init script cleanly. Migration 012 exists so a
volume-preserving upgrade also converges.

## Verification

> **EXECUTED** (2026-09-24) via the **volume-preserving upgrade** path (the harder of the two)
> against the old Alpine-image volume — which already held a real SJ import (152,663 vertices /
> 183,371 edges).

- All items below pass. Implementation bugs caught during the run: (a) `ALTER EXTENSION
  IF EXISTS ... UPDATE` is **invalid syntax** (`pq: syntax error`, killed the first 012 run —
  statement (3) silently lost; 012 reran idempotently after the fix, the earlier statements'
  work committing across the failed run is EXACTLY why they are idempotent), and (b)
  `psql -f` on the shell script feeds `#!/bin/sh` to psql (fixed instructions above), and
  (c) `ls | sort -V` picked the stray `postgresql.conf.sample.dpkg` — now filtered.
- **The rev-1 purge was destructive**: `DELETE ... WHERE id IN (1,2)` / `id=100` removed TWO
  REAL vertices + ONE REAL edge (id gaps confirmed: vertices max 152665 vs count 152663; edges
  max 183372 vs count 183371). Cause: sequential (non-OSM) ids collide with the seed ids. The
  two lost vertex rows were restored from `road_vertices` (same id space, geometry intact).
  The lost edge's endpoints are unrecoverable from retained tables (008 re-sequences edge ids);
  `make import-osm-force` regenerates a pristine graph. The checked-in 012 is now geo-guarded
  (NYC-only purge) so fresh DBs are safe.
- Measured end-state (verified queries):
  - `pg_extension`: `pgrouting|4.0.1`, `postgis|3.5.2`, `postgis_raster|3.5.2`,
    `postgis_topology|3.5.2`, `fuzzystrmatch|1.2` (the pgrouting image DOES ship fuzzystrmatch).
  - `pg_proc`: real C implementation (`prolang=14`), 8-col output
    `(seq,path_seq,start_vid,end_vid,node,edge,cost,agg_cost)` across all 5 overloads —
    matches plan 03's projection requirement, plus an actual `pgr_dijkstra` call routed the SJ
    graph (v1→v2, 56.5 m via edge 5).
  - `schema_migrations`: `011` and `012` both recorded; server boot log shows
    `migration applied: 012_enable_pgrouting`.
  - Post-repair vertices: min 1 / max 152665 / count 152665 (no gaps); edges count 183371 of
    183372 (one lost segment, see above).
  - `go test -count=1 ./...` green (native engine + mocks).
- Fresh-volume path (init script governs): the script was re-run by hand against the live DB
  and is idempotent + control-guarded (both `create` and `skip` branches exercised).

1. Fresh volume: `docker compose down -v && docker compose up -d`; then
   `docker exec ride-hailing-db psql -U ridehail -d ridehailing -Atc "SELECT extname, extversion FROM pg_extension WHERE extname IN ('postgis','pgrouting') ORDER BY 1"` →
   versions **`3.5.2`** and **`4.0.1`** (NOT `3.5`/`4.0` — assert prefixes `LIKE '3.5%'`/
   `LIKE '4.0%'` if you script it).
2. Reused volume: before swapping the image, `docker compose down` (keep volume), swap image
   + migrations, `docker compose up -d`; server boot applies 011(old)→012; then the same
   `pg_extension` query shows 3.5.2 / 4.0.1 and `pg_proc.prolang='14'` (C) for `pgr_dijkstra`.
3. Demo rows purged on a seed-ONLY volume: `SELECT count(*) FROM road_network_vertices_pgr
   WHERE id IN (1,2) AND ST_DWithin(the_geom::geography,
   ST_SetSRID(ST_MakePoint(-74.006,40.7128),4326)::geography, 50000)` → 0 after 012; a volume
   that ALREADY holds a real import is untouched (geo-guard matches nothing). `make import-osm`
   on an empty DB now runs the real import (gate no longer trips on the NYC seed), or
   `make import-osm-force` on an already-populated one.
4. Server boots with zero Go changes: `make run`, `make test` green (native engine; mocks).
5. `docker exec -i ride-hailing-db sh -s < scripts/init-pgrouting.sh` twice — idempotent.

## Alternatives & Future

- **`postgis/postgis:16-3.5` Debian + `apt install postgresql-16-pgrouting`**: an alternative
  if the `pgrouting` image's extension set diverges from what we need; not chosen (the image
  is official and pre-pinned).
- **Never install pgRouting / keep the native engine**: a valid end state if plan 03's
  benchmark gate fails — plans 04–06 keep the native fallback first-class.

## Files to Modify

- `docker-compose.yml` — image tag.
- `scripts/init-pgrouting.sh` — idempotent, extension-verified, runnable by hand.
- `internal/database/migrations/011_create_routing.up.sql` — guard stub + demo seed behind
  extension-absent.
- `internal/database/migrations/012_enable_pgrouting.up.sql` *(new)* — seed purge, three-
  liner convergence, postgis catalog update.
- `scripts/import-road-network.sh` ready-note (gate no longer trips on the seed) — only a
  comment/README touch here.