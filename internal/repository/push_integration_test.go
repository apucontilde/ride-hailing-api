//go:build integration

package repository

import (
	"testing"

	"ride-hailing-api/internal/model"
)

// These tests exercise the real SQL against a live DB using same-named TEMP
// tables on a single-connection handle, so the production tables are never
// touched (the same pattern the ratings/routing integration tests use).

func TestDeviceTokenRepoGlobalTokenReassignmentIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS device_tokens") })

	// Mirrors migration 018: globally-unique token, plus the pre-existing
	// UNIQUE(user_id, token) that a naive implementation relied on.
	mustExec(t, db, `CREATE TEMP TABLE device_tokens (
		id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
		user_id    TEXT        NOT NULL,
		token      TEXT        NOT NULL,
		platform   TEXT        NOT NULL CHECK (platform IN ('ios', 'android', 'web')),
		is_active  BOOLEAN     NOT NULL DEFAULT TRUE,
		created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		UNIQUE(user_id, token)
	)`)
	mustExec(t, db, `CREATE UNIQUE INDEX idx_device_tokens_token ON device_tokens(token)`)

	repo := NewDeviceTokenRepo(db)

	if _, err := repo.Register("user-a", "shared-token", "android"); err != nil {
		t.Fatalf("Register user-a: %v", err)
	}
	assertTokens := func(user string, want int) []model.DeviceToken {
		t.Helper()
		tokens, err := repo.ListActiveTokens(user)
		if err != nil {
			t.Fatalf("ListActiveTokens(%s): %v", user, err)
		}
		if len(tokens) != want {
			t.Fatalf("ListActiveTokens(%s) = %d tokens, want %d", user, len(tokens), want)
		}
		return tokens
	}
	assertTokens("user-a", 1)

	// Re-registering the same (user, token) must not duplicate.
	if _, err := repo.Register("user-a", "shared-token", "android"); err != nil {
		t.Fatalf("re-Register user-a: %v", err)
	}
	assertTokens("user-a", 1)

	// The same device signs in as user B: the token must MOVE, so user A stops
	// being delivered to.
	if _, err := repo.Register("user-b", "shared-token", "ios"); err != nil {
		t.Fatalf("Register user-b: %v", err)
	}
	assertTokens("user-a", 0)
	bTokens := assertTokens("user-b", 1)
	if bTokens[0].Platform != "ios" {
		t.Fatalf("reassigned platform = %q, want ios (the newest registration wins)", bTokens[0].Platform)
	}

	// Unregister is user-scoped and idempotent.
	if err := repo.Unregister("user-a", "shared-token"); err != nil {
		t.Fatalf("Unregister by the non-owner: %v", err)
	}
	assertTokens("user-b", 1) // the other user's token is untouched

	if err := repo.Unregister("user-b", "shared-token"); err != nil {
		t.Fatalf("Unregister by the owner: %v", err)
	}
	assertTokens("user-b", 0)

	// Unregistering an unknown token is a no-op, not an error.
	if err := repo.Unregister("user-b", "never-registered"); err != nil {
		t.Fatalf("Unregister unknown token: %v", err)
	}
}

func TestFeedbackRepoPersistsTypeIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS feedback") })

	mustExec(t, db, `CREATE TEMP TABLE feedback (
		id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
		user_id    TEXT        NOT NULL,
		ride_id    TEXT,
		message    TEXT        NOT NULL,
		type       TEXT        NOT NULL DEFAULT '',
		created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
	)`)

	repo := NewFeedbackRepo(db)
	fb := &model.Feedback{UserID: "user-1", Type: "app_issue", Message: "the button is stuck"}
	if err := repo.CreateFeedback(fb); err != nil {
		t.Fatalf("CreateFeedback: %v", err)
	}
	if fb.ID == "" {
		t.Fatal("CreateFeedback did not populate the generated id")
	}
	if fb.Type != "app_issue" {
		t.Fatalf("returned type = %q, want app_issue", fb.Type)
	}

	var stored string
	if err := db.Get(&stored, "SELECT type FROM feedback WHERE id = $1", fb.ID); err != nil {
		t.Fatalf("read stored type: %v", err)
	}
	if stored != "app_issue" {
		t.Fatalf("stored type = %q, want app_issue", stored)
	}
}
