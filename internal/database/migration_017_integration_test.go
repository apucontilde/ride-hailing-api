//go:build integration

package database

import (
	"fmt"
	"testing"
	"time"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

// TestMigration017ResolvesIdempotencyDuplicates proves the #18 migration applies
// over a duplicate-laden table: with the composite constraint missing (the
// state a volume whose global PK was already dropped would be in), duplicate
// (key, user_id) rows are resolved deterministically — the earliest created_at
// survives — and the composite unique constraint is restored.
//
// It re-executes the actual embedded 017 file, so the SQL under test is the
// migration the runner will apply, not a copy.
func TestMigration017ResolvesIdempotencyDuplicates(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	if err := RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	userA := insertMigrationTestUser(t, db, "017-dup-a")
	userB := insertMigrationTestUser(t, db, "017-dup-b")
	t.Cleanup(func() {
		db.Exec(`DELETE FROM idempotency_keys WHERE user_id IN ($1, $2)`, userA, userB)
		db.Exec(`DELETE FROM users WHERE id IN ($1, $2)`, userA, userB)
	})

	// Simulate the duplicate-laden state: drop the composite constraint, then
	// insert two rows for (key, userA) with different created_at and one for
	// (key, userB) — which must NOT be touched by the dedup.
	if _, err := db.Exec(`ALTER TABLE idempotency_keys DROP CONSTRAINT IF EXISTS idempotency_keys_key_user_id_key`); err != nil {
		t.Fatalf("drop composite constraint: %v", err)
	}
	if _, err := db.Exec(
		`INSERT INTO idempotency_keys (key, user_id, response_status, response_content_type, response_body, created_at)
		 VALUES ('017-dup-key', $1, 200, 'application/json', '"old"',  NOW() - interval '10 minutes'),
		        ('017-dup-key', $1, 200, 'application/json', '"new"',  NOW()),
		        ('017-dup-key', $2, 200, 'application/json', '"other-user"', NOW())`,
		userA, userB); err != nil {
		t.Fatalf("seed duplicates: %v", err)
	}

	// Apply the real migration file over the duplicates.
	content, err := migrationsFS.ReadFile("migrations/017_idempotency_key_scoping.up.sql")
	if err != nil {
		t.Fatalf("read migration file: %v", err)
	}
	if _, err := db.Exec(string(content)); err != nil {
		t.Fatalf("re-apply 017 over duplicates: %v", err)
	}

	// Exactly one row survives for userA (the earliest), and userB keeps theirs.
	var count int
	if err := db.Get(&count, `SELECT COUNT(*) FROM idempotency_keys WHERE key = '017-dup-key'`); err != nil {
		t.Fatalf("count rows: %v", err)
	}
	if count != 2 {
		t.Errorf("rows for the key = %d, want 2 (one per user)", count)
	}

	var survivor string
	if err := db.Get(&survivor,
		`SELECT response_body::text FROM idempotency_keys WHERE key = '017-dup-key' AND user_id = $1`, userA); err != nil {
		t.Fatalf("read survivor: %v", err)
	}
	if survivor != `"old"` {
		t.Errorf("surviving body = %s, want the earliest %q", survivor, `"old"`)
	}

	var present bool
	if err := db.Get(&present,
		`SELECT EXISTS(SELECT 1 FROM pg_constraint WHERE conrelid = 'idempotency_keys'::regclass AND conname = 'idempotency_keys_key_user_id_key')`); err != nil {
		t.Fatalf("constraint probe: %v", err)
	}
	if !present {
		t.Error("idempotency_keys_key_user_id_key is missing after the migration")
	}

	// The composite uniqueness must now reject a duplicate (key, user_id).
	if _, err := db.Exec(
		`INSERT INTO idempotency_keys (key, user_id, response_status, response_content_type, response_body)
		 VALUES ('017-dup-key', $1, 200, 'application/json', '"again"')`, userA); err == nil {
		t.Error("a duplicate (key, user_id) insert must violate the composite unique constraint")
	}
}

// insertMigrationTestUser creates a throwaway user for the FK on
// idempotency_keys.user_id and returns its id.
func insertMigrationTestUser(t *testing.T, db *sqlx.DB, prefix string) string {
	t.Helper()
	suffix := time.Now().UnixNano()
	var id string
	if err := db.Get(&id,
		`INSERT INTO users (email, phone, password_hash) VALUES ($1, $2, 'x') RETURNING id`,
		fmt.Sprintf("%s-%d@migration.test", prefix, suffix),
		fmt.Sprintf("+5060%s%d", prefix, suffix)); err != nil {
		t.Fatalf("insert test user: %v", err)
	}
	return id
}
