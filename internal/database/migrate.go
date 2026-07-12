package database

import (
	"embed"
	"fmt"
	"log"
	"sort"
	"strings"

	"github.com/jmoiron/sqlx"
)

//go:embed migrations/*.up.sql
var migrationsFS embed.FS

type Migration struct {
	Version string
	Name    string
	SQL     string
}

func RunMigrations(db *sqlx.DB) error {
	ensureMigrationsTable(db)

	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return fmt.Errorf("failed to read migrations directory: %w", err)
	}

	var migrationFiles []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".up.sql") {
			migrationFiles = append(migrationFiles, e.Name())
		}
	}
	sort.Strings(migrationFiles)

	for _, file := range migrationFiles {
		version := strings.Split(file, "_")[0]
		name := strings.TrimSuffix(file, ".up.sql")

		var count int
		if err := db.Get(&count, "SELECT COUNT(*) FROM schema_migrations WHERE version = $1", version); err != nil {
			return fmt.Errorf("failed to check migration version: %w", err)
		}
		if count > 0 {
			continue
		}

		content, err := migrationsFS.ReadFile("migrations/" + file)
		if err != nil {
			return fmt.Errorf("failed to read migration %s: %w", file, err)
		}

		sql := string(content)
		if _, err := db.Exec(sql); err != nil {
			return fmt.Errorf("failed to execute migration %s: %w", file, err)
		}

		if _, err := db.Exec("INSERT INTO schema_migrations (version, name) VALUES ($1, $2)", version, name); err != nil {
			return fmt.Errorf("failed to record migration: %w", err)
		}
		log.Printf("migration applied: %s", name)
	}

	return nil
}

func ensureMigrationsTable(db *sqlx.DB) {
	db.MustExec(`
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version     TEXT PRIMARY KEY,
			name        TEXT NOT NULL,
			applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)
	`)
}
