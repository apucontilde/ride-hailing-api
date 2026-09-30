//go:build integration

package database

import (
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

// TestElevationMigrationApplies runs the migration runner against the live dev
// DB (idempotent — already-applied versions are skipped) and asserts the 014
// elevation columns exist on road_network_vertices_pgr. This is the "migration
// applies on startup" proof: cmd/server calls RunMigrations before any repo is
// built.
func TestElevationMigrationApplies(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	if err := RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	for _, col := range []string{"elevation_m", "elevation_source"} {
		var present bool
		if err := db.Get(&present,
			"SELECT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name = 'road_network_vertices_pgr' AND column_name = $1)", col); err != nil {
			t.Fatalf("%s probe: %v", col, err)
		}
		if !present {
			t.Errorf("014 column %q missing from road_network_vertices_pgr", col)
		}
	}
}
