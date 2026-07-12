# Data Population Plan — San José, Costa Rica


## Task 1 — `scripts/download-osm.ps1` (PowerShell)

Downloads the Costa Rica OSM extract and extracts San José province.

**Source:** Geofabrik — `costa-rica-latest.osm.pbf` (~300 MB)

**Boundary:** San José province polygon must be available as `data/san-jose.geojson`.

```powershell
# data/download-osm.ps1
# Usage: ./scripts/download-osm.ps1
```

---

## Task 2 — `scripts/import-road-network.sh`

Idempotent import script:

1. Check for `osm2pgrouting` binary (fail with install instructions)
2. Drop existing `ways`, `ways_vertices_pgr`, `configuration` (osm2pgrouting output)
3. Run `osm2pgrouting` with San José `.pbf`
4. Run `pgr_createTopology` for graph connectivity
5. Copy data into `road_edges` / `road_vertices` (matching migration 006 schema)
6. Drop raw osm2pgrouting tables

**Input:** `data/san-jose.osm.pbf`
**Output:** Populated `road_edges` + `road_vertices` tables

---

## Task 3 — Migration `007_compute_elevation_costs.up.sql`

Compute elevation-aware routing costs:

```sql
-- Helper function (placeholder — returns NULL without DEM)
CREATE OR REPLACE FUNCTION sample_elevation(lon double precision, lat double precision)
RETURNS double precision LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN NULL;  -- plug in DEM raster or external API later
END;
$$;

-- Populate elevation
UPDATE road_vertices SET elevation_m = sample_elevation(lon, lat);

-- Compute gradient and elevation-sensitive costs
UPDATE road_edges e
SET gradient = (vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0),
    cost_elev = CASE
      WHEN vt.elevation_m > vs.elevation_m
        THEN e.cost * (1 + 0.05 * ABS((vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0)))
      ELSE e.cost * (1 + 0.025 * ABS((vt.elevation_m - vs.elevation_m) / NULLIF(e.length_m, 0)))
    END
FROM road_vertices vs, road_vertices vt
WHERE e.source = vs.id AND e.target = vt.id;
```

If no DEM is available, set all `elevation_m = 0` and `cost_elev = cost`.

---

## Task 4 — `scripts/seed.sql`

Test data for San José area:

| Table | Data |
|-------|------|
| `users` | 2 riders, 3 drivers, 1 admin |
| `rider_profiles` | Default payment method, saved places |
| `driver_profiles` | sedan, SUV, bike — all online |
| `driver_positions` | GEOGRAPHY points scattered around SJ downtown, Escazú, Heredia |
| `rider_positions` | Near Sabana Park (9.9333, -84.0833), UCR |
| `rides` | 1 completed ride (Sabana → UCR) with route |
| `ride_events` | Status transitions for the sample ride |
| `ride_ratings` | Rating for completed ride |
| `promotions` | 1 active promo code (`WELCOME10`) |
| `sos_alerts` | 1 resolved alert |
| `user_devices` | 1 device per user |

**Coordinates reference:**
- Sabana Park: 9.9333, -84.0833
- San José downtown: 9.9281, -84.0907
- Escazú: 9.9167, -84.1333
- Heredia: 10.0000, -84.1167
- UCR (Universidad de Costa Rica): 9.9360, -84.0500

---

## Task 5 — Update `Makefile`

Add targets:

```makefile
seed:
	psql "$(DATABASE_URL)" -f scripts/seed.sql

import-osm:
	./scripts/import-road-network.sh

download-osm:
	./scripts/download-osm.ps1
```

---

## Task 6 — `scripts/init-pgrouting.sh`

Ensure pgRouting extension is created (run inside PostGIS container):

```bash
#!/bin/bash
psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE EXTENSION IF NOT EXISTS pgrouting CASCADE;"
```

---

## Notes

- `osm2pgrouting` is not bundled in the PostGIS Docker image — it must be installed on the host or built into a custom image.
- DEM elevation is optional and can be deferred. Without it, `cost_elev = cost` (flat routing).
- The `006_create_road_network` migration creates the target tables empty. osm2pgrouting output is copied into them.
- The `007` migration is run after the import to compute cost_elev.
