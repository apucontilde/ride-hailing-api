// Command elevtool samples an SRTM-class DEM onto the road-network vertices and
// writes the result into road_network_vertices_pgr.elevation_m /
// .elevation_source (api_plans/[elevation]_dem_ingest_and_noise_control.md).
//
// It is deliberately one thing: "sample this DEM onto whatever vertices exist".
// No smoothing, no resampling, no OSM import — those live elsewhere (the cost
// model's deadband/cap is the noise filter, and calibration is a later stage).
package main

import (
	"database/sql"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq" // the postgres driver
)

const skadiBaseURL = "https://elevation-tiles-prod.s3.amazonaws.com/skadi"

// vertex is one routing vertex with its geographic position.
type vertex struct {
	ID  int64
	Lat float64
	Lng float64
}

// sample is one matched vertex → elevation write.
type sample struct {
	id     int64
	ele    float64
	source string
}

func main() {
	log.SetFlags(log.LstdFlags)
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func run() error {
	databaseURL := flag.String("database-url", envDatabaseURL(), "Postgres connection URL")
	demDir := flag.String("dem-dir", "data/dem", "directory to cache downloaded .hgt.gz tiles")
	source := flag.String("source", "skadi", "DEM source tag (recorded as elevation_source prefix)")
	fetch := flag.Bool("fetch", false, "download missing tiles over HTTPS")
	dryRun := flag.Bool("dry-run", false, "print the work set and coverage, do not write")
	region := flag.String("region", "", "scope to one routing_regions row (region_id column required)")
	minCoverage := flag.Float64("min-coverage", 0.98, "minimum matched fraction; exit non-zero below it")
	flag.Parse()

	if *databaseURL == "" {
		return fmt.Errorf("no database URL: pass -database-url or set DB_HOST/DB_PORT/DB_USER/DB_PASSWORD/DB_NAME")
	}

	db, err := sqlx.Open("postgres", *databaseURL)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	defer func() {
		if cerr := db.Close(); cerr != nil {
			log.Printf("close database: %v", cerr)
		}
	}()

	probe, err := probeColumns(db)
	if err != nil {
		return fmt.Errorf("probe schema: %w", err)
	}
	if *region != "" && !probe.regionID {
		return fmt.Errorf("-region was passed but road_network_vertices_pgr has no region_id column; " +
			"refusing to silently sample every region and overwrite (apply the region migration first)")
	}

	// Determine the work set from the vertices themselves.
	verts, err := loadVertices(db, probe, *region)
	if err != nil {
		return fmt.Errorf("load vertices: %w", err)
	}
	if len(verts) == 0 {
		return fmt.Errorf("no vertices found (run make import-osm first)")
	}

	// Compute the tile set from the VERTEX set, never from the bbox corners.
	// A bbox-derived set misses a strip of vertices at an edge that happens to
	// fall in a tile the corners don't span (the N08W084 7-vertex cluster bug).
	tiles := tilesFor(verts)
	tileNames := sortedKeys(tiles)

	log.Printf("vertices: %d  tiles: %d (%s)", len(verts), len(tileNames), strings.Join(tileNames, " "))

	// Load (or fetch) each tile.
	loaded := make(map[string]*Tile, len(tileNames))
	for _, name := range tileNames {
		b, err := loadTile(*demDir, name, *fetch)
		if err != nil {
			// A tile that 404s is reported, not fatal; its vertices stay NULL.
			log.Printf("WARNING: tile %s not loaded: %v", name, err)
			continue
		}
		tile, err := ParseHGT(name, b)
		if err != nil {
			log.Printf("WARNING: tile %s unparseable: %v", name, err)
			continue
		}
		loaded[name] = tile
	}

	// Sample every vertex; unmatched vertices keep their NULL.
	var matched []sample
	var unmatched int
	for _, v := range verts {
		name := tileNameFor(v.Lat, v.Lng)
		tile, ok := loaded[name]
		if !ok {
			unmatched++
			continue
		}
		ele, ok := tile.Sample(v.Lat, v.Lng)
		if !ok {
			unmatched++
			continue
		}
		matched = append(matched, sample{id: v.ID, ele: ele, source: *source + ":" + name})
	}

	frac := 0.0
	if len(verts) > 0 {
		frac = float64(len(matched)) / float64(len(verts))
	}
	log.Printf("matched %d / %d (%.2f%%), unmatched %d", len(matched), len(verts), 100*frac, unmatched)

	if len(matched) > 0 {
		reportRange(matched)
	}

	if *dryRun {
		log.Printf("dry-run: not writing")
		if frac < *minCoverage {
			return fmt.Errorf("coverage %.4f below -min-coverage %.4f; aborting", frac, *minCoverage)
		}
		return nil
	}

	if frac < *minCoverage {
		return fmt.Errorf("matched fraction %.4f below -min-coverage %.4f; aborting (a broken DEM must not half-apply)", frac, *minCoverage)
	}
	if len(matched) == 0 {
		return fmt.Errorf("nothing matched; refusing to write an empty elevation backfill")
	}

	if err := writeElevation(db, matched); err != nil {
		return fmt.Errorf("write elevation: %w", err)
	}
	log.Printf("wrote %d elevations", len(matched))
	return nil
}

// probeColumns reports which columns the routing tables actually have so the
// region probe errors loudly on a pre-region schema rather than silently
// sampling everything.
type schema struct {
	regionID bool
}

func probeColumns(db *sqlx.DB) (schema, error) {
	var cols []string
	if err := db.Select(&cols, `SELECT column_name FROM information_schema.columns
		WHERE table_name = 'road_network_vertices_pgr'`); err != nil {
		return schema{}, err
	}
	var s schema
	for _, c := range cols {
		if c == "region_id" {
			s.regionID = true
		}
	}
	return s, nil
}

func loadVertices(db *sqlx.DB, s schema, region string) ([]vertex, error) {
	q := `SELECT id, ST_Y(the_geom) AS lat, ST_X(the_geom) AS lng FROM road_network_vertices_pgr`
	if region != "" && s.regionID {
		q += ` WHERE region_id = $1`
	}
	var verts []vertex
	var err error
	if region != "" && s.regionID {
		err = db.Select(&verts, q, region)
	} else {
		err = db.Select(&verts, q)
	}
	return verts, err
}

// tilesFor buckets vertices by their own 1° tile, so the fetch set is the
// non-empty subset, not the bbox's full 3×2 block.
func tilesFor(verts []vertex) map[string]int {
	m := map[string]int{}
	for _, v := range verts {
		m[tileNameFor(v.Lat, v.Lng)]++
	}
	return m
}

// loadTile returns the gzipped payload for a tile, from the on-disk cache or
// (with -fetch) over HTTPS. A 404 is returned as an error, and the caller
// reports it rather than crashing.
func loadTile(demDir, name string, fetch bool) ([]byte, error) {
	path := filepath.Join(demDir, name+".hgt.gz")
	if b, err := os.ReadFile(path); err == nil {
		return b, nil
	}
	if !fetch {
		return nil, fmt.Errorf("not cached (run with -fetch)")
	}
	if err := os.MkdirAll(demDir, 0o755); err != nil {
		return nil, err
	}
	url := fmt.Sprintf("%s/%s/%s.hgt.gz", skadiBaseURL, skadiDir(name), name)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer func() {
		if cerr := resp.Body.Close(); cerr != nil {
			log.Printf("close %s: %v", url, cerr)
		}
	}()
	if resp.StatusCode != http.StatusOK {
		if _, drainErr := io.Copy(io.Discard, resp.Body); drainErr != nil {
			log.Printf("drain %s: %v", url, drainErr)
		}
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, b, 0o644); err != nil {
		return nil, err
	}
	log.Printf("fetched %s (%d bytes)", name, len(b))
	return b, nil
}

func reportRange(matched []sample) {
	min, max := matched[0].ele, matched[0].ele
	var sum float64
	for _, m := range matched {
		if m.ele < min {
			min = m.ele
		}
		if m.ele > max {
			max = m.ele
		}
		sum += m.ele
	}
	log.Printf("elevation range: min %.1f max %.1f mean %.1f", min, max, sum/float64(len(matched)))
}

// writeElevation writes matched samples to the existing vertices. The samples
// are COPY'd (FROM STDIN) into a TEMP staging table and then merged with one
// UPDATE ... FROM, because road_network_vertices_pgr.id is a PRIMARY KEY that
// already exists (a direct COPY would violate it). The whole thing runs inside
// a single transaction: lib/pq requires the COPY inside a transaction, and
// atomicity is the point — a half-applied backfill is worse than none. Only
// matched vertices are written; unmatched keep NULL.
func writeElevation(db *sqlx.DB, matched []sample) error {
	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer func() {
		if rerr := tx.Rollback(); rerr != nil && rerr != sql.ErrTxDone {
			log.Printf("rollback: %v", rerr)
		}
	}()

	if _, createErr := tx.Exec(`CREATE TEMP TABLE _elev_backfill (id bigint PRIMARY KEY, elevation_m double precision, elevation_source text) ON COMMIT DROP`); createErr != nil {
		return createErr
	}
	stmt, err := tx.Prepare(`COPY _elev_backfill (id, elevation_m, elevation_source) FROM STDIN`)
	if err != nil {
		return err
	}
	for _, m := range matched {
		if _, execErr := stmt.Exec(m.id, m.ele, m.source); execErr != nil {
			if cerr := stmt.Close(); cerr != nil {
				log.Printf("close copy: %v", cerr)
			}
			return execErr
		}
	}
	if _, flushErr := stmt.Exec(); flushErr != nil { // empty Exec flushes the COPY
		if cerr := stmt.Close(); cerr != nil {
			log.Printf("close copy: %v", cerr)
		}
		return flushErr
	}
	if err := stmt.Close(); err != nil {
		return err
	}

	if _, mergeErr := tx.Exec(`UPDATE road_network_vertices_pgr v
		SET elevation_m = b.elevation_m, elevation_source = b.elevation_source
		FROM _elev_backfill b
		WHERE v.id = b.id`); mergeErr != nil {
		return mergeErr
	}
	return tx.Commit()
}

func sortedKeys(m map[string]int) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// envDatabaseURL builds a connection URL from the same env vars the Makefile
// and the API use, so the tool works with zero flags in this repo's harness.
func envDatabaseURL() string {
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		getenv("DB_USER", "ridehail"), getenv("DB_PASSWORD", "ridehail_pass"),
		getenv("DB_HOST", "localhost"), getenv("DB_PORT", "5432"),
		getenv("DB_NAME", "ridehailing"), getenv("DB_SSLMODE", "disable"))
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
