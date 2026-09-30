package middleware

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
)

// maxIdempotencyBodyBytes caps the response copy a keyed request holds in
// memory. Past the cap nothing more is captured and nothing is stored: a
// truncated body would replay as a corrupt success.
const maxIdempotencyBodyBytes = 1 << 20 // 1 MiB

// idempotencyStore is the persistence seam for Idempotency. It exists so the
// middleware is unit-testable without a live database: the repo has no
// go-sqlmock, and the branches that matter (an unreadable stored pair, a losing
// Store) are unreachable through a real *sqlx.DB without fault injection.
type idempotencyStore interface {
	Count(key, userID string) (int, error)
	Load(key, userID string) (int, json.RawMessage, error)
	// Store reports whether the row was written; false with a nil error means
	// the key was already recorded.
	Store(key, userID string, status int, body []byte) (bool, error)
}

// sqlIdempotencyStore is the production idempotencyStore, backed by the
// idempotency_keys table (migration 007). Its `key` is a bare PRIMARY KEY, so
// it is not user-scoped: ownership is provable only through Count, and UNIQUE
// (key, user_id) is the follow-up migration.
type sqlIdempotencyStore struct {
	db *sqlx.DB
}

func (s *sqlIdempotencyStore) Count(key, userID string) (int, error) {
	var count int
	err := s.db.Get(&count,
		"SELECT COUNT(*) FROM idempotency_keys WHERE key = $1 AND user_id = $2", key, userID)
	return count, err
}

func (s *sqlIdempotencyStore) Load(key, userID string) (int, json.RawMessage, error) {
	// Two reads, not one: a failure of either column must abort the replay,
	// because a zero status or a nil body would answer the client with a lie.
	var status int
	if err := s.db.Get(&status, "SELECT response_status FROM idempotency_keys WHERE key = $1 AND user_id = $2", key, userID); err != nil {
		return 0, nil, err
	}
	var body json.RawMessage
	if err := s.db.Get(&body, "SELECT response_body FROM idempotency_keys WHERE key = $1 AND user_id = $2", key, userID); err != nil {
		return 0, nil, err
	}
	return status, body, nil
}

func (s *sqlIdempotencyStore) Store(key, userID string, status int, body []byte) (bool, error) {
	res, err := s.db.Exec(
		"INSERT INTO idempotency_keys (key, user_id, response_status, response_body) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
		key, userID, status, string(body),
	)
	if err != nil {
		return false, err
	}
	// ON CONFLICT DO NOTHING reports success while writing nothing, so the row
	// count is the only way to notice a dropped write.
	affected, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return affected > 0, nil
}

func Idempotency(db *sqlx.DB) gin.HandlerFunc {
	// A nil *sqlx.DB means "no idempotency available" (the test suite wires the
	// router with db=nil) and must disable the middleware entirely; a non-nil
	// store over a nil db would panic on every call.
	if db == nil {
		return idempotencyWithStore(nil)
	}
	return idempotencyWithStore(&sqlIdempotencyStore{db: db})
}

// captureWriter tees the handler's body so the real payload can be stored for
// replay. It wraps the real writer rather than replacing it, so the handler,
// the logger and gin keep the same ResponseWriter they had.
type captureWriter struct {
	gin.ResponseWriter
	buf      bytes.Buffer
	overflow bool
}

// reserve reports whether n more bytes fit under the cap, latching overflow so
// capture stops for the rest of the response.
func (w *captureWriter) reserve(n int) bool {
	if w.overflow || w.buf.Len()+n > maxIdempotencyBodyBytes {
		w.overflow = true
		return false
	}
	return true
}

func (w *captureWriter) Write(b []byte) (int, error) {
	// The tee must not fail the request; a bytes.Buffer write cannot error.
	if w.reserve(len(b)) {
		_, _ = w.buf.Write(b)
	}
	return w.ResponseWriter.Write(b)
}

// WriteString must be overridden, not promoted: gin implements it as
// io.WriteString(w.ResponseWriter, s) (gin/response_writer.go), which bypasses
// Write, so the promoted method would capture nothing. No gin render path uses
// it — c.String and c.JSON both go through Write — but a handler calling
// io.WriteString(c.Writer, …) does, and capturing nothing is the bug this
// middleware exists to prevent.
func (w *captureWriter) WriteString(s string) (int, error) {
	if w.reserve(len(s)) {
		_, _ = w.buf.WriteString(s)
	}
	return w.ResponseWriter.WriteString(s)
}

func (w *captureWriter) body() []byte { return w.buf.Bytes() }

// Only 200 and 201 are recorded: a 4xx/5xx is exactly what a retry must not be
// pinned to, and the other 2xx statuses (202, 204, 205, 304) either carry no
// body to replay or must not carry one.
func isReplayableStatus(status int) bool {
	return status == http.StatusOK || status == http.StatusCreated
}

// idempotencyWithStore is Idempotency with an injected store; the router must
// keep calling the public Idempotency(db) constructor.
func idempotencyWithStore(store idempotencyStore) gin.HandlerFunc {
	return func(c *gin.Context) {
		key := c.GetHeader("Idempotency-Key")
		if key == "" || store == nil {
			c.Next()
			return
		}

		userID, _ := c.Get("user_id")
		userIDStr, _ := userID.(string)

		if count, err := store.Count(key, userIDStr); err == nil && count > 0 {
			status, body, readErr := store.Load(key, userIDStr)
			switch {
			case readErr != nil:
				log.Printf("idempotency: stored response for key %q unreadable (%v); re-running handler", key, readErr)
			case status < 100 || status > 599:
				// gin treats WriteHeader(0) as a no-op, so replaying an
				// out-of-range status would answer a silent, bodyless 200.
				log.Printf("idempotency: stored response for key %q has implausible status %d; re-running handler", key, status)
			default:
				c.AbortWithStatusJSON(status, body)
				return
			}
		}

		c.Set("idempotency_key", key)

		// Installed before c.Next() and read after: that window is the only time
		// the handler's writes are observable. Deferred so a panicking handler
		// cannot leave the request writing into a dead buffer.
		cw := &captureWriter{ResponseWriter: c.Writer}
		c.Writer = cw
		defer func() { c.Writer = cw.ResponseWriter }()

		c.Next()

		status := c.Writer.Status()
		if !isReplayableStatus(status) {
			return
		}
		rawKey, exists := c.Get("idempotency_key")
		storedKey, isString := rawKey.(string)
		if !exists || !isString {
			return
		}
		if cw.overflow {
			log.Printf("idempotency: response for key %q exceeded the %d-byte capture cap; not stored",
				storedKey, maxIdempotencyBodyBytes)
			return
		}
		// Best-effort: the store is a replay cache, not part of the transaction,
		// so a failed INSERT must never change a response the client is due.
		stored, err := store.Store(storedKey, userIDStr, status, replayableBody(cw.body()))
		switch {
		case err != nil:
			log.Printf("idempotency: failed to store response for key %q: %v", storedKey, err)
		case !stored:
			// The key was already recorded under that bare primary key, so this
			// response is dropped — usually a client reusing another user's key,
			// whose Count is then always 0. Fixed by UNIQUE(key, user_id).
			log.Printf("WARNING: idempotency: key %q already recorded, response not stored; a retry will re-run the handler", storedKey)
		}
	}
}

// replayableBody normalises a captured body into a valid JSONB document for the
// idempotency_keys.response_body column, which is NOT NULL: an empty capture
// cannot be stored as-is and a non-JSON body is not a JSONB document at all.
// Rather than store a lie — the pre-fix code stored a literal `{}`, which replays
// as a success with a missing payload — an empty body becomes JSON null and a
// non-JSON body becomes a JSON string.
//
// The replay is c.AbortWithStatusJSON, i.e. json.Marshal under Content-Type:
// application/json, so a non-JSON original comes back JSON-quoted and
// HTML-significant bytes come back \u-escaped; only JSON objects and arrays
// round-trip byte-for-byte. Replaying under the original Content-Type (c.Data)
// needs a response_content_type column, deliberately not added here.
func replayableBody(captured []byte) []byte {
	trimmed := bytes.TrimSpace(captured)
	if len(trimmed) == 0 {
		return []byte("null")
	}
	if json.Valid(trimmed) {
		return trimmed
	}
	// A string always marshals.
	encoded, _ := json.Marshal(string(trimmed))
	return encoded
}
