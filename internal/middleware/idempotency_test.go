package middleware

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// These are the tests for bug #9 (api_plans [errors]_idempotency_middleware_tests):
// the idempotency middleware had NO test at all, so several rules were
// unenforced — "an unreadable or implausible stored pair must RE-RUN, never
// replay", "only a 200/201 is stored" and "a replay is scoped to the key's
// owner". A future edit could reintroduce AbortWithStatusJSON(0, nil) and
// answer a client with a zero status without CI noticing.
//
// The seam under test is the unexported idempotencyStore; the public
// Idempotency(db) constructor and the router call site are unchanged, and are
// exercised separately by TestIdempotencyNilStoreIsInert below.

// fakeStore is a scriptable idempotencyStore. Every method records that it was
// called, so a test can assert not just the response but also that the handler
// did or did not run.
type fakeStore struct {
	// count is what Count reports, and countErr its failure.
	count    int
	countErr error
	// loadStatus/loadContentType/loadBody are what Load returns, and loadErr its
	// failure.
	loadStatus      int
	loadContentType string
	loadBody        json.RawMessage
	loadErr         error
	// storeErr fails Store; storeDropped makes Store report a losing
	// ON CONFLICT DO NOTHING insert.
	storeErr     error
	storeDropped bool

	countCalls  int
	countKey    string
	countUser   string
	loadCalls   int
	loadKey     string
	loadUser    string
	storeCalls  int
	storeKey    string
	storeUser   string
	storeStatus int
	storeCT     string
	storeBody   []byte
}

func (f *fakeStore) Count(key, userID string) (int, error) {
	f.countCalls++
	f.countKey, f.countUser = key, userID
	return f.count, f.countErr
}

func (f *fakeStore) Load(key, userID string) (int, string, json.RawMessage, error) {
	f.loadCalls++
	f.loadKey, f.loadUser = key, userID
	return f.loadStatus, f.loadContentType, f.loadBody, f.loadErr
}

func (f *fakeStore) Store(key, userID string, status int, contentType string, body []byte) (bool, error) {
	f.storeCalls++
	f.storeKey, f.storeUser, f.storeStatus, f.storeCT, f.storeBody = key, userID, status, contentType, body
	if f.storeErr != nil {
		return false, f.storeErr
	}
	return !f.storeDropped, nil
}

// captureLogs redirects the standard logger for the duration of the test, so a
// test can pin the one signal a swallowed write leaves behind.
func captureLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	prevOut, prevFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(prevOut); log.SetFlags(prevFlags) })
	return &buf
}

// runIdempotency mounts the middleware in front of a counting handler and
// performs one request. The handler's status is chosen by name so each test
// reads as a scenario rather than a number, and the call count comes back so a
// test can assert the handler did or did not run.
func runIdempotency(t *testing.T, store idempotencyStore, key, handlerStatus, handlerBody string) (*httptest.ResponseRecorder, *int) {
	t.Helper()
	gin.SetMode(gin.TestMode)

	// The handler's own status is parameterised by name.
	status := map[string]int{
		"ok":           http.StatusOK,
		"created":      http.StatusCreated,
		"accepted":     http.StatusAccepted,
		"no_content":   http.StatusNoContent,
		"bad_request":  http.StatusBadRequest,
		"server_error": http.StatusInternalServerError,
	}[handlerStatus]
	if status == 0 {
		t.Fatalf("unknown handlerStatus %q", handlerStatus)
	}

	ran := new(int)
	r := gin.New()
	// The middleware reads user_id off the context, so the auth stand-in runs
	// before it — the same ordering the router uses.
	r.Use(func(c *gin.Context) {
		c.Set("user_id", "user-1")
		c.Next()
	})
	r.Use(idempotencyWithStore(store))
	r.POST("/x", func(c *gin.Context) {
		*ran++
		// The JSON content type is explicit: the production mount point
		// (POST /api/v1/rides) is a JSON handler, and the middleware keys its
		// body wrapping on the content type.
		c.Data(status, "application/json; charset=utf-8", []byte(handlerBody))
	})

	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	if key != "" {
		req.Header.Set("Idempotency-Key", key)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w, ran
}

// TestIdempotencyNoKeyIsInert pins the bypass: without a key there is nothing to
// deduplicate, so the handler runs and the store is never touched.
func TestIdempotencyNoKeyIsInert(t *testing.T) {
	store := &fakeStore{}
	w, ran := runIdempotency(t, store, "", "ok", `{"ok":true}`)

	if *ran != 1 {
		t.Errorf("handler ran %d times, want 1", *ran)
	}
	if store.countCalls != 0 || store.loadCalls != 0 || store.storeCalls != 0 {
		t.Errorf("store touched: count=%d load=%d store=%d, want all 0 without a key",
			store.countCalls, store.loadCalls, store.storeCalls)
	}
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
}

// TestIdempotencyNilStoreIsInert is the db=nil path: the public constructor must
// disable the middleware, not wrap a nil db in a store that panics on every
// call. The tests/ suite wires the router with db=nil and relies on this.
func TestIdempotencyNilStoreIsInert(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(Idempotency(nil))
	ran := 0
	r.POST("/x", func(c *gin.Context) {
		ran++
		c.String(http.StatusOK, `{"ok":true}`)
	})

	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Idempotency-Key", "some-key")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req) // must not panic

	if ran != 1 {
		t.Errorf("handler ran %d times, want 1", ran)
	}
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
}

// TestIdempotencyReplaysStoredResponse is the happy path of the replay: an
// existing key with a fully readable pair is answered from storage, and the
// handler must NOT run (running it would double-charge a retry).
func TestIdempotencyReplaysStoredResponse(t *testing.T) {
	stored := json.RawMessage(`{"ride":{"id":"r-1"},"stored":true}`)
	store := &fakeStore{count: 1, loadStatus: http.StatusCreated, loadContentType: "application/json; charset=utf-8", loadBody: stored}
	w, ran := runIdempotency(t, store, "key-1", "ok", `{"ride":{"id":"r-2"}}`)

	if *ran != 0 {
		t.Errorf("handler ran %d times, want 0: a replay must not re-execute the handler", *ran)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want the stored %d", w.Code, http.StatusCreated)
	}
	if got := w.Body.String(); got != string(stored) {
		t.Errorf("body = %q, want the stored %q", got, stored)
	}
	if got := w.Header().Get("Content-Type"); got != "application/json; charset=utf-8" {
		t.Errorf("Content-Type = %q, want the stored application/json", got)
	}
	if store.storeCalls != 0 {
		t.Errorf("Store called %d times on a replay, want 0", store.storeCalls)
	}
	// Both queries must carry the owner: Count scopes ownership, and a Load
	// that dropped user_id is the one way a stored pair could answer the wrong
	// user once the key stops being a bare primary key.
	if store.countKey != "key-1" || store.countUser != "user-1" {
		t.Errorf("Count called with (%q, %q), want (\"key-1\", \"user-1\")", store.countKey, store.countUser)
	}
	if store.loadKey != "key-1" || store.loadUser != "user-1" {
		t.Errorf("Load called with (%q, %q), want (\"key-1\", \"user-1\")", store.loadKey, store.loadUser)
	}
}

// TestIdempotencyUnreadableStoredResponseReRunsHandler is the partial-read rule:
// a stored pair that cannot be read back must re-run the handler. Replaying
// here would answer with the zero value from the failed read — the
// AbortWithStatusJSON(0, nil) bug.
func TestIdempotencyUnreadableStoredResponseReRunsHandler(t *testing.T) {
	store := &fakeStore{
		count:      1,
		loadStatus: 0,
		loadBody:   nil,
		loadErr:    errors.New("pq: connection reset by peer"),
	}
	w, ran := runIdempotency(t, store, "key-1", "ok", `{"fresh":true}`)

	if *ran != 1 {
		t.Errorf("handler ran %d times, want 1: an unreadable stored pair must re-run, not replay", *ran)
	}
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want the handler's 200, never a 0 from a failed read", w.Code)
	}
	if got := w.Body.String(); got != `{"fresh":true}` {
		t.Errorf("body = %q, want the freshly handled body", got)
	}
}

// TestIdempotencyImplausibleStoredStatusReRunsHandler guards a readable row
// whose response_status is not a real HTTP status. gin treats WriteHeader(0) as
// a no-op, so replaying it would answer a silent bodyless 200 to a client that
// had already been charged.
func TestIdempotencyImplausibleStoredStatusReRunsHandler(t *testing.T) {
	cases := []struct {
		name   string
		status int
	}{
		{"zero (gin ignores WriteHeader(0))", 0},
		{"negative", -1},
		{"below 100", 99},
		{"above 599", 600},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeStore{
				count:      1,
				loadStatus: tc.status,
				loadBody:   json.RawMessage(`{"stale":true}`),
			}
			w, ran := runIdempotency(t, store, "key-1", "ok", `{"fresh":true}`)

			if *ran != 1 {
				t.Errorf("handler ran %d times, want 1: stored status %d must not replay", *ran, tc.status)
			}
			if w.Code != http.StatusOK {
				t.Errorf("status = %d, want the handler's 200, never the stored %d", w.Code, tc.status)
			}
			if got := w.Body.String(); got != `{"fresh":true}` {
				t.Errorf("body = %q, want the freshly handled body", got)
			}
		})
	}
}

// TestIdempotencyCountFailureFallsThroughToHandling pins the other tolerance:
// a failing COUNT is not a partial read, it just means "I don't know", so the
// request is handled normally rather than replayed.
func TestIdempotencyCountFailureFallsThroughToHandling(t *testing.T) {
	store := &fakeStore{countErr: errors.New("pq: too many connections")}
	w, ran := runIdempotency(t, store, "key-1", "ok", `{"fresh":true}`)

	if *ran != 1 {
		t.Errorf("handler ran %d times, want 1", *ran)
	}
	if store.loadCalls != 0 {
		t.Errorf("Load called %d times after a Count failure, want 0", store.loadCalls)
	}
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
}

// TestIdempotencyStoresOnlySuccessResponses pins what may be recorded under a
// key. A failed request must NOT be recorded as the answer for that key, or a
// retry after a transient 500 would replay the failure forever. The rule is
// 200/201 only, not "2xx": 202/204 are not stored because a retry of an
// accepted-but-bodyless response has no payload to replay.
func TestIdempotencyStoresOnlySuccessResponses(t *testing.T) {
	cases := []struct {
		name       string
		status     string
		wantStatus int
		wantStore  int
	}{
		{"200 is stored", "ok", http.StatusOK, 1},
		{"201 is stored", "created", http.StatusCreated, 1},
		{"202 is not stored", "accepted", http.StatusAccepted, 0},
		{"204 is not stored", "no_content", http.StatusNoContent, 0},
		{"4xx is not stored", "bad_request", http.StatusBadRequest, 0},
		{"5xx is not stored", "server_error", http.StatusInternalServerError, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := &fakeStore{}
			w, ran := runIdempotency(t, store, "key-1", tc.status, `{"x":1}`)

			if *ran != 1 {
				t.Errorf("handler ran %d times, want 1", *ran)
			}
			if w.Code != tc.wantStatus {
				t.Errorf("status = %d, want %d", w.Code, tc.wantStatus)
			}
			if store.storeCalls != tc.wantStore {
				t.Errorf("Store called %d times, want %d", store.storeCalls, tc.wantStore)
			}
			if tc.wantStore == 1 {
				if store.storeStatus != tc.wantStatus {
					t.Errorf("stored status = %d, want the response's %d", store.storeStatus, tc.wantStatus)
				}
				if store.storeKey != "key-1" {
					t.Errorf("stored key = %q, want %q", store.storeKey, "key-1")
				}
				if store.storeUser != "user-1" {
					t.Errorf("stored user = %q, want the authenticated %q", store.storeUser, "user-1")
				}
			}
		})
	}
}

// TestIdempotencyStoreFailureLeavesResponseUnchanged pins the fault tolerance:
// a failed store INSERT is logged and the client still gets the real response.
// Failing the request instead would tell a user their ride was not created when
// it was — the store is an optimisation, not part of the transaction.
func TestIdempotencyStoreFailureLeavesResponseUnchanged(t *testing.T) {
	store := &fakeStore{storeErr: errors.New("pq: disk full")}
	w, ran := runIdempotency(t, store, "key-1", "created", `{"ride":{"id":"r-1"}}`)

	if *ran != 1 {
		t.Errorf("handler ran %d times, want 1", *ran)
	}
	if store.storeCalls != 1 {
		t.Errorf("Store called %d times, want 1 (the failure must be attempted)", store.storeCalls)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want the handler's 201: a failed store must not change the response", w.Code)
	}
	if got := w.Body.String(); got != `{"ride":{"id":"r-1"}}` {
		t.Errorf("body = %q, want the handler's body unchanged", got)
	}
}

// TestIdempotencyZeroCountHandlesNormally closes the loop between Count and the
// handler: a key that has never been seen must be handled and then recorded.
func TestIdempotencyZeroCountHandlesNormally(t *testing.T) {
	store := &fakeStore{count: 0}
	w, ran := runIdempotency(t, store, "brand-new", "created", `{"ride":{"id":"r-1"}}`)

	if *ran != 1 {
		t.Errorf("handler ran %d times, want 1", *ran)
	}
	if store.loadCalls != 0 {
		t.Errorf("Load called %d times on a new key, want 0", store.loadCalls)
	}
	if store.storeCalls != 1 {
		t.Errorf("Store called %d times on a new 201, want 1", store.storeCalls)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want 201", w.Code)
	}
}

// The tests below are for [errors]_idempotent_replay_body: the middleware used
// to store json.Marshal(gin.H{}) — a literal "{}" — as the replay body, so a
// replayed create returned the right STATUS with an empty payload. That is
// worse than no idempotency at all: it looks like a successful response with
// missing data.

// TestIdempotencyStoresTheHandlersRealBody is the core fix: the stored body must
// equal what the handler actually wrote, not a hardcoded empty object.
func TestIdempotencyStoresTheHandlersRealBody(t *testing.T) {
	const realBody = `{"ride":{"id":"ride-42","status":"pending"}}`
	store := &fakeStore{}
	w, ran := runIdempotency(t, store, "key-body", "created", realBody)

	if *ran != 1 {
		t.Fatalf("handler ran %d times, want 1", *ran)
	}
	if store.storeCalls != 1 {
		t.Fatalf("Store called %d times, want 1", store.storeCalls)
	}
	if got := string(store.storeBody); got != realBody {
		t.Errorf("stored body = %q, want the handler's actual body %q", got, realBody)
	}
	// The client still gets the handler's real response, unchanged.
	if got := w.Body.String(); got != realBody {
		t.Errorf("response body = %q, want %q", got, realBody)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want 201", w.Code)
	}
}

// TestIdempotencyReplayReturnsTheOriginalBody is the payoff: a second request
// with the same key must come back byte-identical to the first, and the handler
// must not run again.
func TestIdempotencyReplayReturnsTheOriginalBody(t *testing.T) {
	const original = `{"ride":{"id":"ride-42","status":"pending"},"fare":{"total":1250}}`

	// First request: records the response.
	first := &fakeStore{}
	w1, ran1 := runIdempotency(t, first, "key-replay", "created", original)
	if *ran1 != 1 {
		t.Fatalf("first request: handler ran %d times, want 1", *ran1)
	}
	if first.storeCalls != 1 {
		t.Fatalf("first request: Store called %d times, want 1", first.storeCalls)
	}

	// Second request, same key: the store now reports the recorded pair, exactly
	// as sqlIdempotencyStore would after a real INSERT.
	second := &fakeStore{
		count:           1,
		loadStatus:      first.storeStatus,
		loadContentType: first.storeCT,
		loadBody:        append(json.RawMessage(nil), first.storeBody...),
	}
	w2, ran2 := runIdempotency(t, second, "key-replay", "created", `{"ride":{"id":"ride-99"}}`)

	if *ran2 != 0 {
		t.Errorf("replay: handler ran %d times, want 0", *ran2)
	}
	if w2.Code != w1.Code {
		t.Errorf("replay status = %d, want the original %d", w2.Code, w1.Code)
	}
	if got := w2.Body.String(); got != original {
		t.Errorf("replay body = %q, want the original %q", got, original)
	}
	if second.storeCalls != 0 {
		t.Errorf("replay: Store called %d times, want 0", second.storeCalls)
	}
}

// TestIdempotencyCapturesWriteStringBodies guards the override that is easiest
// to forget. gin implements ResponseWriter.WriteString as
// io.WriteString(w.ResponseWriter, s) — it does NOT go through Write — so a
// handler that calls io.WriteString(c.Writer, …) would capture nothing at all
// with only Write overridden, and the response would look fine while the stored
// replay body was empty. (gin's own renders never take this path: c.String and
// c.JSON both end in w.Write, which is why c.String is not used here — it
// would pass with or without the override.)
func TestIdempotencyCapturesWriteStringBodies(t *testing.T) {
	gin.SetMode(gin.TestMode)
	const body = `{"via":"WriteString"}`

	store := &fakeStore{}
	ran := 0
	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.POST("/x", func(c *gin.Context) {
		ran++
		// io.WriteString sees gin.ResponseWriter's StringWriter and calls
		// captureWriter.WriteString, never captureWriter.Write.
		if _, err := io.WriteString(c.Writer, body); err != nil {
			t.Errorf("handler write failed: %v", err)
		}
	})

	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Idempotency-Key", "k-writestring")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if ran != 1 {
		t.Fatalf("handler ran %d times, want 1", ran)
	}
	if store.storeCalls != 1 {
		t.Fatalf("Store called %d times, want 1", store.storeCalls)
	}
	if got := string(store.storeBody); got != body {
		t.Errorf("stored body = %q, want %q (the WriteString path must be captured)", got, body)
	}
	if got := w.Body.String(); got != body {
		t.Errorf("response body = %q, want %q unchanged", got, body)
	}
}

// TestReplayableBodyKeepsInsertValid pins the normalisation. response_body is
// NOT NULL JSONB, so whatever the handler wrote must be turned into something
// storable — without ever inventing a payload that the client did not receive.
//
// The wrapping is keyed on the CONTENT TYPE: a non-JSON type is always
// JSON-string-encoded, even when the bytes are themselves valid JSON, so the
// replay can tell "raw JSON document" from "wrapped non-JSON bytes".
func TestReplayableBodyKeepsInsertValid(t *testing.T) {
	const jsonCT = "application/json; charset=utf-8"
	const textCT = "text/plain; charset=utf-8"
	const htmlCT = "text/html; charset=utf-8"
	cases := []struct {
		name        string
		contentType string
		captured    string
		want        string
	}{
		{"json object passes through", jsonCT, `{"a":1}`, `{"a":1}`},
		{"json array passes through", jsonCT, `[1,2,3]`, `[1,2,3]`},
		{"json null stays null", jsonCT, `null`, `null`},
		{"json string literal stays raw", jsonCT, `"quoted"`, `"quoted"`},
		{"json surrounding whitespace is trimmed", jsonCT, "  {\"a\":1}\n", `{"a":1}`},
		{"empty body becomes json null", jsonCT, ``, `null`},
		{"non-json plain text is wrapped", textCT, `plain text`, `"plain text"`},
		{"non-json null literal is wrapped, not stored as json null", textCT, `null`, `"null"`},
		// The bug the reviewer reproduced: a non-JSON body that is a valid JSON
		// string literal must NOT be stored raw, or the replay cannot tell it
		// apart from a wrapped body and strips the quotes.
		{"non-json quoted literal is wrapped", textCT, `"quoted"`, `"\"quoted\""`},
		// Whitespace-only must survive: the old trim-then-check stored `null`.
		{"non-json whitespace is preserved", textCT, "  ", `"  "`},
		{"empty non-json body becomes json null", textCT, ``, `null`},
		// encoding/json HTML-escapes <, > and & by default. That is still the
		// same string once parsed, and it is the safe form to keep in a JSONB
		// column, so the escaping is expected rather than a defect.
		{"non-json html is wrapped, html-escaped", htmlCT, `<h1>hi</h1>`, `"<h1>hi</h1>"`},
		{"empty content type behaves as json", ``, `{"a":1}`, `{"a":1}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := string(replayableBody(tc.contentType, []byte(tc.captured)))
			if tc.name == "non-json html is wrapped, html-escaped" {
				// Compare after a JSON round-trip so the assertion is about the
				// VALUE, not about encoding/json's escaping policy.
				var wantAny, gotAny interface{}
				if err := json.Unmarshal([]byte(tc.want), &wantAny); err != nil {
					t.Fatalf("bad expectation %q: %v", tc.want, err)
				}
				if err := json.Unmarshal([]byte(got), &gotAny); err != nil {
					t.Fatalf("replayableBody(%q, %q) = %q, not valid JSON: %v", tc.contentType, tc.captured, got, err)
				}
				if gotAny != wantAny {
					t.Errorf("replayableBody(%q, %q) decoded to %v, want %v", tc.contentType, tc.captured, gotAny, wantAny)
				}
			} else if got != tc.want {
				t.Errorf("replayableBody(%q, %q) = %q, want %q", tc.contentType, tc.captured, got, tc.want)
			}
			if !json.Valid([]byte(got)) {
				t.Errorf("replayableBody(%q, %q) = %q, which is not valid JSON and would fail the JSONB INSERT",
					tc.contentType, tc.captured, got)
			}
		})
	}
}

// TestNonJSONReplayRoundTripsExactBytes is the byte-for-byte property the
// reviewer's counterexamples broke: for every non-JSON body — including a valid
// JSON string literal and whitespace-only bytes — storing then replaying must
// return the exact original bytes. It exercises the same store/replay functions
// the middleware calls.
func TestNonJSONReplayRoundTripsExactBytes(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"plain text", "OK, plain text payload"},
		{"valid json string literal", `"quoted"`},
		{"whitespace only", "  "},
		{"json null literal", "null"},
		{"html-significant bytes", `<h1>hi</h1> & <b>bye</b>`},
		{"empty", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			const ct = "text/plain; charset=utf-8"
			stored := replayableBody(ct, []byte(tc.body))
			if !json.Valid(stored) {
				t.Fatalf("stored %q is not valid JSONB and the INSERT would fail", stored)
			}
			got := string(replayBody(ct, json.RawMessage(stored)))
			if got != tc.body {
				t.Errorf("round-trip = %q, want the exact original %q", got, tc.body)
			}
		})
	}
}

// TestIdempotencyEmptySuccessBodyIsStoredValidly covers the 200-with-no-body
// case end to end: the INSERT must still be attempted with a storable value
// rather than skipped, and the response must not change.
func TestIdempotencyEmptySuccessBodyIsStoredValidly(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &fakeStore{}

	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.GET("/x", func(c *gin.Context) {
		c.Status(http.StatusNoContent) // no body at all
	})

	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Idempotency-Key", "k-empty")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Errorf("status = %d, want 204", w.Code)
	}
	// 204 is not 200/201, so nothing is stored at all.
	if store.storeCalls != 0 {
		t.Errorf("Store called %d times for a 204, want 0", store.storeCalls)
	}

	// Now the 200-with-no-body case, which IS in the store path.
	store2 := &fakeStore{}
	r2 := gin.New()
	r2.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r2.Use(idempotencyWithStore(store2))
	r2.GET("/y", func(c *gin.Context) {
		c.Status(http.StatusOK) // success, no body
	})
	req2 := httptest.NewRequest(http.MethodGet, "/y", nil)
	req2.Header.Set("Idempotency-Key", "k-empty-200")
	w2 := httptest.NewRecorder()
	r2.ServeHTTP(w2, req2)

	if store2.storeCalls != 1 {
		t.Fatalf("Store called %d times for a bodyless 200, want 1", store2.storeCalls)
	}
	if got := string(store2.storeBody); !json.Valid([]byte(got)) {
		t.Errorf("stored body %q is not valid JSONB and the INSERT would fail", got)
	}
	if w2.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w2.Code)
	}
}

// TestIdempotencyNonJSONBodyIsStoredWithoutChangingTheResponse pins the
// plan's "a non-JSON/empty body is handled without a failed INSERT changing the
// response" requirement.
func TestIdempotencyNonJSONBodyIsStoredWithoutChangingTheResponse(t *testing.T) {
	gin.SetMode(gin.TestMode)
	const text = "OK, plain text payload"
	store := &fakeStore{}

	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.GET("/x", func(c *gin.Context) {
		c.String(http.StatusOK, text)
	})

	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Idempotency-Key", "k-text")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	// The client is unaffected...
	if got := w.Body.String(); got != text {
		t.Errorf("response body = %q, want %q unchanged", got, text)
	}
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
	// ...and what was stored is still a valid JSONB document.
	if store.storeCalls != 1 {
		t.Fatalf("Store called %d times, want 1", store.storeCalls)
	}
	if !json.Valid(store.storeBody) {
		t.Errorf("stored body %q is not valid JSONB", store.storeBody)
	}
}

// TestIdempotencyNonJSONReplayIsFaithful is the bug #17 payoff: a replay must
// echo the ORIGINAL Content-Type and the ORIGINAL bytes. The stored JSONB body
// goes through the JSON-string form for a non-JSON handler, so the middleware
// has to unwrap it rather than call AbortWithStatusJSON (which JSON-quoted a
// text/plain body and \u-escaped HTML-significant bytes).
func TestIdempotencyNonJSONReplayIsFaithful(t *testing.T) {
	cases := []struct {
		name        string
		contentType string
		body        string
	}{
		{"plain text", "text/plain; charset=utf-8", "OK, plain text payload"},
		{"html is not json-escaped", "text/html; charset=utf-8", `<h1>hi</h1> & <b>bye</b>`},
		// The reviewer's counterexamples: a non-JSON body that is itself a valid
		// JSON string literal, and whitespace-only bytes.
		{"valid json string literal", "text/plain; charset=utf-8", `"quoted"`},
		{"whitespace only", "text/plain; charset=utf-8", "  "},
		{"empty", "text/plain; charset=utf-8", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gin.SetMode(gin.TestMode)
			first := &fakeStore{}
			r := gin.New()
			r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
			r.Use(idempotencyWithStore(first))
			r.GET("/x", func(c *gin.Context) { c.Data(http.StatusOK, tc.contentType, []byte(tc.body)) })
			req := httptest.NewRequest(http.MethodGet, "/x", nil)
			req.Header.Set("Idempotency-Key", "k-nonjson")
			r.ServeHTTP(httptest.NewRecorder(), req)

			if first.storeCalls != 1 {
				t.Fatalf("first Store calls = %d, want 1", first.storeCalls)
			}
			if first.storeCT != tc.contentType {
				t.Errorf("stored Content-Type = %q, want the handler's %q", first.storeCT, tc.contentType)
			}

			// Second request, same key: replay the recorded pair exactly as the
			// real store would return it.
			second := &fakeStore{
				count:           1,
				loadStatus:      first.storeStatus,
				loadContentType: first.storeCT,
				loadBody:        append(json.RawMessage(nil), first.storeBody...),
			}
			r2 := gin.New()
			r2.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
			r2.Use(idempotencyWithStore(second))
			r2.GET("/x", func(c *gin.Context) { c.String(http.StatusOK, "a different body") })
			req2 := httptest.NewRequest(http.MethodGet, "/x", nil)
			req2.Header.Set("Idempotency-Key", "k-nonjson")
			w2 := httptest.NewRecorder()
			r2.ServeHTTP(w2, req2)

			if second.loadCalls != 1 {
				t.Fatalf("Load called %d times, want 1", second.loadCalls)
			}
			if got := w2.Body.String(); got != tc.body {
				t.Errorf("replay body = %q, want the original %q (not JSON-quoted/escaped)", got, tc.body)
			}
			if got := w2.Header().Get("Content-Type"); got != tc.contentType {
				t.Errorf("replay Content-Type = %q, want the original %q", got, tc.contentType)
			}
		})
	}
}

// TestIdempotencyEmptyKeyHeaderIsInert covers the header that is present but
// blank, which is a different condition from the absent header in
// TestIdempotencyNoKeyIsInert: an empty key must not be treated as a shared key
// by every client that sends one.
func TestIdempotencyEmptyKeyHeaderIsInert(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &fakeStore{}
	ran := 0

	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.POST("/x", func(c *gin.Context) {
		ran++
		c.String(http.StatusCreated, `{"ride":{"id":"r-1"}}`)
	})

	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header["Idempotency-Key"] = []string{""} // present, no value
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if ran != 1 {
		t.Errorf("handler ran %d times, want 1", ran)
	}
	if store.countCalls != 0 || store.loadCalls != 0 || store.storeCalls != 0 {
		t.Errorf("store touched: count=%d load=%d store=%d, want all 0 for a blank key",
			store.countCalls, store.loadCalls, store.storeCalls)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want 201", w.Code)
	}
}

// TestIdempotencyStoreConflictLeavesResponseUnchanged covers the losing
// ON CONFLICT DO NOTHING insert. The response is a success either way — the
// client keeps what it earned — but nothing is recorded, so a retry re-runs the
// handler. The live case is a second user reusing a key they do not own: their
// Count is 0 forever and idempotency is silently off for them. The warning log
// is the only signal that exists, so Store must report the drop and the drop
// must be logged.
func TestIdempotencyStoreConflictLeavesResponseUnchanged(t *testing.T) {
	logs := captureLogs(t)
	store := &fakeStore{storeDropped: true}
	w, ran := runIdempotency(t, store, "key-1", "created", `{"ride":{"id":"r-1"}}`)

	if *ran != 1 {
		t.Errorf("handler ran %d times, want 1", *ran)
	}
	if store.storeCalls != 1 {
		t.Errorf("Store called %d times, want 1 (the conflict must be visible, not swallowed)", store.storeCalls)
	}
	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want the handler's 201: a dropped store must not change the response", w.Code)
	}
	if got := w.Body.String(); got != `{"ride":{"id":"r-1"}}` {
		t.Errorf("body = %q, want the handler's body unchanged", got)
	}
	if got := logs.String(); !strings.Contains(got, `key "key-1" already recorded`) {
		t.Errorf("logs = %q, want a warning that the key was already recorded", got)
	}
}

// TestIdempotencyNonStringStoredKeyDoesNotPanic covers the defensive type
// assertion: anything downstream of the middleware can overwrite the
// idempotency_key it put on the context, and `storedKey.(string)` without the
// comma-ok form would panic inside the request.
func TestIdempotencyNonStringStoredKeyDoesNotPanic(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &fakeStore{}

	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.POST("/x", func(c *gin.Context) {
		c.Set("idempotency_key", 42) // hostile overwrite
		c.String(http.StatusCreated, `{"ride":{"id":"r-1"}}`)
	})

	req := httptest.NewRequest(http.MethodPost, "/x", nil)
	req.Header.Set("Idempotency-Key", "key-1")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req) // must not panic

	if w.Code != http.StatusCreated {
		t.Errorf("status = %d, want 201", w.Code)
	}
	if store.storeCalls != 0 {
		t.Errorf("Store called %d times with a non-string key, want 0", store.storeCalls)
	}
}

// TestIdempotencyOversizeCaptureIsNotStored pins the capture cap. Every keyed
// request otherwise holds a second full copy of the response in memory; past
// maxIdempotencyBodyBytes the middleware must stop capturing and store nothing
// at all (a truncated body would replay as a corrupt success), while the client
// still gets the full response.
func TestIdempotencyOversizeCaptureIsNotStored(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &fakeStore{}
	ran := 0
	oversize := strings.Repeat("x", maxIdempotencyBodyBytes+1024)

	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.GET("/x", func(c *gin.Context) {
		ran++
		c.String(http.StatusOK, oversize)
	})

	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Idempotency-Key", "k-huge")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if ran != 1 {
		t.Fatalf("handler ran %d times, want 1", ran)
	}
	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", w.Code)
	}
	if got := w.Body.String(); got != oversize {
		t.Errorf("response body is %d bytes, want the full %d: the cap must not truncate the response",
			len(got), len(oversize))
	}
	if store.storeCalls != 0 {
		t.Errorf("Store called %d times for a %d-byte body over the %d-byte cap, want 0",
			store.storeCalls, len(oversize), maxIdempotencyBodyBytes)
	}
}

// TestIdempotencyCaptureUnderCapIsStored is the other half of the cap: a body
// at the limit is still captured and stored, so the cap cannot silently disable
// idempotency.
func TestIdempotencyCaptureUnderCapIsStored(t *testing.T) {
	gin.SetMode(gin.TestMode)
	store := &fakeStore{}
	atCap := strings.Repeat("x", maxIdempotencyBodyBytes)

	r := gin.New()
	r.Use(func(c *gin.Context) { c.Set("user_id", "user-1"); c.Next() })
	r.Use(idempotencyWithStore(store))
	r.GET("/x", func(c *gin.Context) { c.String(http.StatusOK, atCap) })

	req := httptest.NewRequest(http.MethodGet, "/x", nil)
	req.Header.Set("Idempotency-Key", "k-at-cap")
	r.ServeHTTP(httptest.NewRecorder(), req)

	if store.storeCalls != 1 {
		t.Fatalf("Store called %d times for a body exactly at the cap, want 1", store.storeCalls)
	}
	if got := len(store.storeBody); got <= maxIdempotencyBodyBytes {
		t.Errorf("stored %d bytes, want the whole %d-byte body", got, maxIdempotencyBodyBytes)
	}
}
