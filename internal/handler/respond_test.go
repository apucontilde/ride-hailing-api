package handler

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/repository"
)

func newTestContext() (*gin.Context, *httptest.ResponseRecorder) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	return c, w
}

func TestRespondRepoNotFound(t *testing.T) {
	c, w := newTestContext()
	// wrapDB-shaped error: operation prefix, the taxonomy sentinel, and the
	// underlying driver error all chained with %w.
	err := fmt.Errorf("load user: %w: %w", repository.ErrNotFound, errors.New("sql: no rows in result set"))

	respondRepo(c, err, "user not found", "conflict", "internal failure")

	if w.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", w.Code)
	}
	var resp ErrorResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if resp.Error.Code != "NOT_FOUND" || resp.Error.Message != "user not found" {
		t.Fatalf("envelope = %+v, want NOT_FOUND / user not found", resp.Error)
	}
	if len(c.Errors) != 1 || !strings.Contains(c.Errors[0].Error(), "no rows") {
		t.Fatalf("c.Errors = %v, want one entry carrying the driver cause", c.Errors)
	}
}

func TestRespondRepoConflict(t *testing.T) {
	c, w := newTestContext()
	err := fmt.Errorf("create user: %w: %w", repository.ErrConflict, errors.New("pq: duplicate key"))

	respondRepo(c, err, "not found", "Account already exists", "internal failure")

	if w.Code != http.StatusConflict {
		t.Fatalf("status = %d, want 409", w.Code)
	}
	var resp ErrorResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if resp.Error.Code != "CONFLICT" || resp.Error.Message != "Account already exists" {
		t.Fatalf("envelope = %+v, want CONFLICT / Account already exists", resp.Error)
	}
}

func TestRespondRepoUnclassified(t *testing.T) {
	for _, err := range []error{
		errors.New("boom"),
		fmt.Errorf("pq: connection refused: %w", errors.New("driver down")),
	} {
		c, w := newTestContext()

		respondRepo(c, err, "not found", "conflict", "failed to load nearby drivers")

		if w.Code != http.StatusInternalServerError {
			t.Fatalf("status = %d, want 500", w.Code)
		}
		var resp ErrorResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("decode envelope: %v", err)
		}
		if resp.Error.Code != "INTERNAL" {
			t.Fatalf("code = %q, want INTERNAL", resp.Error.Code)
		}
		// The caller's own operation sentence is what reaches the client, not a
		// substitute like "internal error". This pins the operation-specific
		// decision against quiet decay into a shared string.
		if resp.Error.Message != "failed to load nearby drivers" {
			t.Fatalf("message = %q, want the caller's own %q", resp.Error.Message, "failed to load nearby drivers")
		}
	}
}

// TestRespondRepoBodyNeverLeaksCause is the invariant-5 regression test: the
// error body must never carry the cause's text ("log it, don't return it").
func TestRespondRepoBodyNeverLeaksCause(t *testing.T) {
	cases := []struct {
		name   string
		err    error
		status int
	}{
		{"not found", fmt.Errorf("load: %w: %w", repository.ErrNotFound, errors.New("boom secret rows")), http.StatusNotFound},
		{"conflict", fmt.Errorf("create: %w: %w", repository.ErrConflict, errors.New("boom secret constraint")), http.StatusConflict},
		{"internal", errors.New("boom secret driver"), http.StatusInternalServerError},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, w := newTestContext()
			respondRepo(c, tc.err, "not found", "conflict", "internal failure")

			if w.Code != tc.status {
				t.Fatalf("status = %d, want %d", w.Code, tc.status)
			}
			body := w.Body.String()
			if strings.Contains(body, "boom secret") {
				t.Fatalf("body leaks cause text: %s", body)
			}
			if len(c.Errors) == 0 || !strings.Contains(c.Errors[0].Error(), "boom secret") {
				t.Fatalf("cause not preserved in c.Errors: %v", c.Errors)
			}
		})
	}
}

func TestFailWithNilCauseAppendsNothing(t *testing.T) {
	c, _ := newTestContext()
	start := len(c.Errors)

	fail(c, http.StatusBadRequest, "BAD_REQUEST", "no ratee found", nil)

	if len(c.Errors) != start {
		t.Fatalf("c.Errors grew from %d to %d on nil cause; must not add a nil entry", start, len(c.Errors))
	}
}

func TestFailEnvelopeShape(t *testing.T) {
	c, w := newTestContext()
	fail(c, http.StatusBadRequest, "BAD_REQUEST", "invalid rating", errors.New("score out of range"))

	var body map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if _, ok := body["error"].(map[string]interface{}); !ok {
		t.Fatalf("envelope must be {\"error\":{...}}, got %v", body)
	}
}

func TestBindJSONValidationErrorUsesPublicLabel(t *testing.T) {
	c, w := newTestContext()
	// A registerRequest with a missing email trips the required tag on the
	// `email` field; the public label "Email" must appear, not the Go names.
	c.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"phone":"+15550000004","password":"SecurePass1"}`))
	c.Request.Header.Set("Content-Type", "application/json")

	if bindJSON(c, &registerRequest{}, "") {
		t.Fatal("bindJSON returned true for an invalid body")
	}

	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422", w.Code)
	}
	var resp ErrorResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if resp.Error.Code != "VALIDATION_ERROR" {
		t.Fatalf("code = %q, want VALIDATION_ERROR", resp.Error.Code)
	}
	if !strings.Contains(resp.Error.Message, "Invalid Email") {
		t.Fatalf("message = %q, want it to name the public label \"Email\"", resp.Error.Message)
	}
	for _, leak := range []string{"registerRequest", "PickupLat", "binding", "required"} {
		if strings.Contains(resp.Error.Message, leak) {
			t.Fatalf("message leaks validator internals %q: %q", leak, resp.Error.Message)
		}
	}
}

func TestBindJSONValidationErrorPickupLatitude(t *testing.T) {
	c, w := newTestContext()
	// rideRequest: each coordinate is `required`; omitting pickup_lat must name
	// "Pickup latitude", not the Go field "PickupLat".
	body := `{"pickup_lng":-46.6333,"dropoff_lat":-23.561,"dropoff_lng":-46.656}`
	c.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")

	if bindJSON(c, &rideRequest{}, "") {
		t.Fatal("bindJSON returned true for an invalid body")
	}

	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422", w.Code)
	}
	var resp ErrorResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if !strings.Contains(resp.Error.Message, "Pickup latitude") {
		t.Fatalf("message = %q, want \"Pickup latitude\"", resp.Error.Message)
	}
	if strings.Contains(resp.Error.Message, "PickupLat") {
		t.Fatalf("message leaks Go field name: %q", resp.Error.Message)
	}
}

func TestBindJSONMalformedBody(t *testing.T) {
	c, w := newTestContext()
	c.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{`))
	c.Request.Header.Set("Content-Type", "application/json")

	if bindJSON(c, &loginRequest{}, "") {
		t.Fatal("bindJSON returned true for a malformed body")
	}

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", w.Code)
	}
	var resp ErrorResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode envelope: %v", err)
	}
	if resp.Error.Code != "BAD_REQUEST" || resp.Error.Message != "Malformed request body" {
		t.Fatalf("envelope = %+v, want BAD_REQUEST / \"Malformed request body\"", resp.Error)
	}
	if len(c.Errors) == 0 {
		t.Fatal("cause was not attached to c.Errors for a malformed body")
	}
}

func TestBindJSONValidBody(t *testing.T) {
	c, w := newTestContext()
	c.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(`{"email":"a@b.co","password":"SecurePass1"}`))
	c.Request.Header.Set("Content-Type", "application/json")

	var req loginRequest
	if !bindJSON(c, &req, "") {
		t.Fatal("bindJSON returned false for a valid body")
	}
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (nothing written)", w.Code)
	}
	if w.Body.Len() != 0 {
		t.Fatalf("valid body wrote a response: %s", w.Body.String())
	}
	if req.Email != "a@b.co" {
		t.Fatalf("email = %q, want decoded value", req.Email)
	}
	if len(c.Errors) != 0 {
		t.Fatalf("valid body attached an error: %v", c.Errors)
	}
}
