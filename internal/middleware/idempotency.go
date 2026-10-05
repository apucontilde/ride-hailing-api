package middleware

import (
	"bytes"
	"encoding/json"
	"log"
	"net/http"
	"strings"

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
	// Load returns the stored status, the Content-Type the handler wrote, and
	// the body as it sits in the JSONB column.
	Load(key, userID string) (int, string, json.RawMessage, error)
	// Store reports whether the row was written; false with a nil error means
	// the pair was already recorded.
	Store(key, userID string, status int, contentType string, body []byte) (bool, error)
}

// sqlIdempotencyStore is the production idempotencyStore, backed by the
// idempotency_keys table (migration 007; scoped by migration 017). Its unique
// key is (key, user_id), so two users may reuse the same key without colliding
// or reading back each other's replay.
type sqlIdempotencyStore struct {
	db *sqlx.DB
}

func (s *sqlIdempotencyStore) Count(key, userID string) (int, error) {
	var count int
	err := s.db.Get(&count,
		"SELECT COUNT(*) FROM idempotency_keys WHERE key = $1 AND user_id = $2", key, userID)
	return count, err
}

func (s *sqlIdempotencyStore) Load(key, userID string) (int, string, json.RawMessage, error) {
	// One row read: a failure of any column must abort the replay, because a
	// zero status, a nil body or a missing content type would answer the client
	// with a lie. A single scan cannot half-succeed, so the property the old
	// two-read comment protected still holds.
	var row struct {
		Status      int             `db:"response_status"`
		ContentType string          `db:"response_content_type"`
		Body        json.RawMessage `db:"response_body"`
	}
	if err := s.db.Get(&row,
		"SELECT response_status, response_content_type, response_body FROM idempotency_keys WHERE key = $1 AND user_id = $2",
		key, userID); err != nil {
		return 0, "", nil, err
	}
	return row.Status, row.ContentType, row.Body, nil
}

func (s *sqlIdempotencyStore) Store(key, userID string, status int, contentType string, body []byte) (bool, error) {
	res, err := s.db.Exec(
		"INSERT INTO idempotency_keys (key, user_id, response_status, response_content_type, response_body) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (key, user_id) DO NOTHING",
		key, userID, status, contentType, string(body),
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

// contentType is the header the handler wrote, captured with the body so a
// replay can echo it. Read after c.Next(), once every write has happened.
func (w *captureWriter) contentType() string { return w.Header().Get("Content-Type") }

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
			status, contentType, body, readErr := store.Load(key, userIDStr)
			switch {
			case readErr != nil:
				log.Printf("idempotency: stored response for key %q unreadable (%v); re-running handler", key, readErr)
			case status < 100 || status > 599:
				// gin treats WriteHeader(0) as a no-op, so replaying an
				// out-of-range status would answer a silent, bodyless 200.
				log.Printf("idempotency: stored response for key %q has implausible status %d; re-running handler", key, status)
			default:
				// Replay under the ORIGINAL Content-Type, not JSON: a
				// text/plain or HTML body stored as a JSON string must come
				// back as those bytes, not as a JSON-quoted/escaped document.
				c.Abort()
				c.Data(status, replayContentType(contentType), replayBody(contentType, body))
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
		contentType := cw.contentType()
		stored, err := store.Store(storedKey, userIDStr, status, contentType, replayableBody(contentType, cw.body()))
		switch {
		case err != nil:
			log.Printf("idempotency: failed to store response for key %q: %v", storedKey, err)
		case !stored:
			// The pair was already recorded (a concurrent retry of the same
			// request), so this response is dropped. With UNIQUE(key, user_id)
			// a different user reusing the key no longer collides here.
			log.Printf("WARNING: idempotency: key %q already recorded for this user, response not stored; a retry will re-run the handler", storedKey)
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
// The wrapping decision is keyed on the CONTENT TYPE, never on whether the bytes
// happen to parse as JSON. That distinction is load-bearing: a non-JSON body may
// itself be a valid JSON document (`"quoted"`, `null`, `  ` whitespace), and
// storing it raw would make replayBody unable to tell "already a JSON document"
// from "a JSON string wrapping the real bytes". For a non-JSON type the EXACT
// captured bytes are therefore always JSON-string-encoded — quotes, whitespace
// and all — so the round-trip through JSONB is byte-for-byte.
//
// The original Content-Type is stored alongside (response_content_type) and
// replayed verbatim. Idempotency is currently mounted only on
// POST /api/v1/rides (internal/router/router.go:173), whose handler is JSON, so
// the non-JSON branch is correctness insurance rather than a live path today.
func replayableBody(contentType string, captured []byte) []byte {
	// An empty body has no bytes to preserve; JSON null is the one value that
	// (a) satisfies the NOT NULL JSONB column and (b) replays as no bytes for a
	// non-JSON type (replayBody unwraps `null` to the empty string).
	if len(captured) == 0 {
		return []byte("null")
	}
	if contentType == "" || isJSONContentType(contentType) {
		// A JSON handler's bytes ARE a JSON document; store them as such. An
		// invalid document (a handler bug) is still wrapped so the JSONB INSERT
		// cannot fail and change the client's response.
		trimmed := bytes.TrimSpace(captured)
		if json.Valid(trimmed) {
			return trimmed
		}
		encoded, _ := json.Marshal(string(trimmed))
		return encoded
	}
	// A non-JSON body: always JSON-string-encode the EXACT bytes, even when
	// they are themselves valid JSON. json.Marshal escapes HTML-significant
	// bytes; replayBody's json.Unmarshal reverses that, so the value survives.
	encoded, _ := json.Marshal(string(captured))
	return encoded
}

// isJSONContentType reports whether ct names a JSON media type, including the
// +json structured suffix (application/problem+json).
func isJSONContentType(ct string) bool {
	return strings.Contains(strings.ToLower(ct), "json")
}

// replayContentType is the header a replay is written under. A handler that
// wrote no explicit type was replayed as JSON before this fix, so that stays
// the fallback when the stored value is empty.
func replayContentType(ct string) string {
	if strings.TrimSpace(ct) == "" {
		return "application/json; charset=utf-8"
	}
	return ct
}

// replayBody returns the bytes a replay must write. For a JSON media type the
// JSONB body is the handler's own bytes. For a non-JSON media type replayableBody
// ALWAYS stored the body as a JSON string, so it is always unwrapped here back
// to the exact original bytes — including a body that was itself a JSON string
// literal. JSON null (an empty capture) unwraps to no bytes.
func replayBody(contentType string, body json.RawMessage) []byte {
	if len(body) == 0 {
		return nil
	}
	if contentType == "" || isJSONContentType(contentType) {
		return body
	}
	var s string
	if err := json.Unmarshal(body, &s); err == nil {
		return []byte(s)
	}
	return body
}
