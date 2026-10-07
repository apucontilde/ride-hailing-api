//go:build integration

package middleware

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/database"
)

// TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres is the #17 proof through
// REAL Postgres: the body round-trips through the JSONB column (which the
// fakeStore tests never exercise), so the encoding bug the reviewer reproduced
// is actually caught. For every non-JSON body — a valid JSON string literal, a
// whitespace-only body, plain text, empty, and HTML-significant bytes — the
// replay returns the exact original bytes under the exact original Content-Type.
func TestIdempotencyNonJSONReplayIsFaithfulThroughPostgres(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := database.RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	user := insertStoreTestUser(t, db, "017-replay")
	t.Cleanup(func() {
		db.Exec(`DELETE FROM idempotency_keys WHERE user_id = $1`, user)
		db.Exec(`DELETE FROM users WHERE id = $1`, user)
	})

	store := &sqlIdempotencyStore{db: db}
	cases := []struct {
		name        string
		key         string
		contentType string
		body        string
	}{
		{"plain text", "017-replay-text", "text/plain; charset=utf-8", "OK, plain text payload"},
		{"valid json string literal", "017-replay-quoted", "text/plain; charset=utf-8", `"quoted"`},
		{"whitespace only", "017-replay-ws", "text/plain; charset=utf-8", "  "},
		{"empty", "017-replay-empty", "text/plain; charset=utf-8", ""},
		{"html-significant bytes", "017-replay-html", "text/html; charset=utf-8", `<h1>hi</h1> & <b>bye</b>`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gin.SetMode(gin.TestMode)

			// First request: the handler writes the non-JSON response, which the
			// middleware stores in Postgres.
			first := gin.New()
			first.Use(func(c *gin.Context) { c.Set("user_id", user); c.Next() })
			first.Use(idempotencyWithStore(store))
			first.GET("/x", func(c *gin.Context) { c.Data(http.StatusOK, tc.contentType, []byte(tc.body)) })
			req := httptest.NewRequest(http.MethodGet, "/x", nil)
			req.Header.Set("Idempotency-Key", tc.key)
			w1 := httptest.NewRecorder()
			first.ServeHTTP(w1, req)
			if w1.Code != http.StatusOK || w1.Body.String() != tc.body {
				t.Fatalf("first response = (%d, %q), want (200, %q)", w1.Code, w1.Body.String(), tc.body)
			}

			// Second request, same key: must replay the stored pair, not re-run.
			second := gin.New()
			second.Use(func(c *gin.Context) { c.Set("user_id", user); c.Next() })
			second.Use(idempotencyWithStore(store))
			second.GET("/x", func(c *gin.Context) { c.String(http.StatusOK, "a different body") })
			req2 := httptest.NewRequest(http.MethodGet, "/x", nil)
			req2.Header.Set("Idempotency-Key", tc.key)
			w2 := httptest.NewRecorder()
			second.ServeHTTP(w2, req2)

			if got := w2.Body.String(); got != tc.body {
				t.Errorf("replay body = %q, want the exact original %q", got, tc.body)
			}
			if got := w2.Header().Get("Content-Type"); got != tc.contentType {
				t.Errorf("replay Content-Type = %q, want the original %q", got, tc.contentType)
			}
		})
	}
}

// TestIdempotencyJSONReplayIsFaithfulThroughPostgres is the bug #22 proof: the
// JSON / empty content-type branch must replay the EXACT captured bytes under
// the original Content-Type. Because JSONB canonicalises a JSON document, the
// middleware stores the body as a JSON string; these cases exercise that shape
// through REAL Postgres — compact JSON, surrounding whitespace/trailing newline
// (the old `bytes.TrimSpace` bug), key order/numeric formatting, and an empty
// body (the old `null`-for-empty bug, which must replay as zero bytes).
func TestIdempotencyJSONReplayIsFaithfulThroughPostgres(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := database.RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	user := insertStoreTestUser(t, db, "022-json-replay")
	t.Cleanup(func() {
		db.Exec(`DELETE FROM idempotency_keys WHERE user_id = $1`, user)
		db.Exec(`DELETE FROM users WHERE id = $1`, user)
	})

	const ct = "application/json; charset=utf-8"
	store := &sqlIdempotencyStore{db: db}
	cases := []struct {
		name string
		key  string
		body string
	}{
		{"compact json", "022-json-compact", `{"ride":{"id":"r-1","status":"pending"},"fare":{"total_cents":1250}}`},
		{"trailing newline and surrounding spaces", "022-json-ws", "  {\"ride\":{\"id\":\"r-1\"}}\n"},
		{"key order and numeric formatting", "022-json-order", `{"b":1,"a":2.50}`},
		{"empty body replays zero bytes", "022-json-empty", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gin.SetMode(gin.TestMode)

			// First request: the handler writes the JSON response, which the
			// middleware stores in Postgres.
			first := gin.New()
			first.Use(func(c *gin.Context) { c.Set("user_id", user); c.Next() })
			first.Use(idempotencyWithStore(store))
			first.GET("/x", func(c *gin.Context) { c.Data(http.StatusOK, ct, []byte(tc.body)) })
			req := httptest.NewRequest(http.MethodGet, "/x", nil)
			req.Header.Set("Idempotency-Key", tc.key)
			w1 := httptest.NewRecorder()
			first.ServeHTTP(w1, req)
			if w1.Code != http.StatusOK || w1.Body.String() != tc.body {
				t.Fatalf("first response = (%d, %q), want (200, %q)", w1.Code, w1.Body.String(), tc.body)
			}

			// Second request, same key: must replay the stored pair, not re-run.
			second := gin.New()
			second.Use(func(c *gin.Context) { c.Set("user_id", user); c.Next() })
			second.Use(idempotencyWithStore(store))
			second.GET("/x", func(c *gin.Context) { c.String(http.StatusOK, "a different body") })
			req2 := httptest.NewRequest(http.MethodGet, "/x", nil)
			req2.Header.Set("Idempotency-Key", tc.key)
			w2 := httptest.NewRecorder()
			second.ServeHTTP(w2, req2)

			if got := w2.Body.String(); got != tc.body {
				t.Errorf("replay body = %q, want the exact original %q", got, tc.body)
			}
			if got := w2.Header().Get("Content-Type"); got != ct {
				t.Errorf("replay Content-Type = %q, want the original %q", got, ct)
			}
		})
	}
}

// TestIdempotencyOldRawJSONRowReplaysThroughPostgres covers the back-compat
// branch against REAL Postgres: a pre-change row stored a JSON body as a raw
// JSON document in the JSONB column. It cannot unmarshal into a string, so
// replayBody returns it verbatim; JSONB canonicalises it, so the replayed VALUE
// is asserted rather than the exact bytes (the middleware must not fail).
func TestIdempotencyOldRawJSONRowReplaysThroughPostgres(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := database.RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	user := insertStoreTestUser(t, db, "022-old-json")
	t.Cleanup(func() {
		db.Exec(`DELETE FROM idempotency_keys WHERE user_id = $1`, user)
		db.Exec(`DELETE FROM users WHERE id = $1`, user)
	})

	const key = "022-old-json-key"
	if _, err := db.Exec(
		`INSERT INTO idempotency_keys (key, user_id, response_status, response_content_type, response_body) VALUES ($1,$2,$3,$4,$5)`,
		key, user, http.StatusCreated, "application/json; charset=utf-8", `{"ride":{"id":"old"}}`,
	); err != nil {
		t.Fatalf("insert old-shape row: %v", err)
	}

	gin.SetMode(gin.TestMode)
	store := &sqlIdempotencyStore{db: db}
	ran := 0
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", user); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.GET("/x", func(c *gin.Context) {
		ran++
		c.String(http.StatusOK, "fresh")
	})
	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Idempotency-Key", key)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if ran != 0 {
		t.Errorf("handler ran %d times, want 0: the old row must replay", ran)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want the stored 201", w.Code)
	}
	var gotVal, wantVal interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &gotVal); err != nil {
		t.Fatalf("replayed old row %q is not JSON: %v", w.Body.String(), err)
	}
	if err := json.Unmarshal([]byte(`{"ride":{"id":"old"}}`), &wantVal); err != nil {
		t.Fatalf("want not JSON: %v", err)
	}
	if fmt.Sprint(gotVal) != fmt.Sprint(wantVal) {
		t.Errorf("replayed value = %v, want %v", gotVal, wantVal)
	}
}

// TestSQLIdempotencyStoreScopesKeysPerUser is the #18 proof at the store layer:
// two users may use the SAME Idempotency-Key without colliding, and neither can
// read back the other's stored replay. Before the fix (`key` was a bare PRIMARY
// KEY) the second user's INSERT was dropped by ON CONFLICT DO NOTHING, so their
// Count was 0 forever and idempotency was silently off for them.
func TestSQLIdempotencyStoreScopesKeysPerUser(t *testing.T) {
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := database.RunMigrations(db); err != nil {
		t.Fatalf("RunMigrations: %v", err)
	}

	userA := insertStoreTestUser(t, db, "017-store-a")
	userB := insertStoreTestUser(t, db, "017-store-b")
	t.Cleanup(func() {
		db.Exec(`DELETE FROM idempotency_keys WHERE user_id IN ($1, $2)`, userA, userB)
		db.Exec(`DELETE FROM users WHERE id IN ($1, $2)`, userA, userB)
	})

	store := &sqlIdempotencyStore{db: db}
	const key = "017-shared-key"
	bodyA := []byte(`{"owner":"a"}`)
	bodyB := []byte(`{"owner":"b"}`)

	storedA, err := store.Store(key, userA, 201, "application/json", bodyA)
	if err != nil || !storedA {
		t.Fatalf("Store for user A = (%v, %v), want (true, nil): the first use must be recorded", storedA, err)
	}
	// The same key for a DIFFERENT user must also be recorded, not swallowed by
	// the old global-key conflict.
	storedB, err := store.Store(key, userB, 201, "application/json", bodyB)
	if err != nil || !storedB {
		t.Fatalf("Store for user B = (%v, %v), want (true, nil): a different user's key must not collide", storedB, err)
	}

	for _, tc := range []struct {
		name string
		user string
		want []byte
	}{
		{"user A", userA, bodyA},
		{"user B", userB, bodyB},
	} {
		t.Run(tc.name, func(t *testing.T) {
			count, err := store.Count(key, tc.user)
			if err != nil || count != 1 {
				t.Fatalf("Count = (%d, %v), want (1, nil)", count, err)
			}
			status, ct, body, err := store.Load(key, tc.user)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if status != 201 {
				t.Errorf("status = %d, want 201", status)
			}
			if ct != "application/json" {
				t.Errorf("Content-Type = %q, want application/json", ct)
			}
			var got, want interface{}
			if err := json.Unmarshal(body, &got); err != nil {
				t.Fatalf("body %s not JSON: %v", body, err)
			}
			if err := json.Unmarshal(tc.want, &want); err != nil {
				t.Fatalf("want not JSON: %v", err)
			}
			if fmt.Sprint(got) != fmt.Sprint(want) {
				t.Errorf("body = %v, want %v (a user must not read another user's replay)", got, want)
			}
		})
	}
}

// insertStoreTestUser creates a throwaway user for the FK on
// idempotency_keys.user_id.
func insertStoreTestUser(t *testing.T, db *sqlx.DB, prefix string) string {
	t.Helper()
	suffix := time.Now().UnixNano()
	var id string
	if err := db.Get(&id,
		`INSERT INTO users (email, phone, password_hash) VALUES ($1, $2, 'x') RETURNING id`,
		fmt.Sprintf("%s-%d@store.test", prefix, suffix),
		fmt.Sprintf("+5070%s%d", prefix, suffix)); err != nil {
		t.Fatalf("insert test user: %v", err)
	}
	return id
}
