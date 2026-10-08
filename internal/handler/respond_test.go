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

// TestRespondRepoClassification is the one table for respondRepo's three-way
// split (404 NOT_FOUND / 409 CONFLICT / 500 INTERNAL) plus invariant 5: the
// public body must never carry the cause's text ("log it, don't return it").
// (Consolidated from TestRespondRepoNotFound, TestRespondRepoConflict,
// TestRespondRepoUnclassified and TestRespondRepoBodyNeverLeaksCause.)
func TestRespondRepoClassification(t *testing.T) {
	cases := []struct {
		name        string
		err         error
		notFound    string
		conflict    string
		internal    string
		wantStatus  int
		wantCode    string
		wantMessage string
		wantCause   string // must be recoverable from c.Errors
		leak        string // must NOT appear in the response body
	}{
		{
			name:        "not_found",
			err:         fmt.Errorf("load user: %w: %w", repository.ErrNotFound, errors.New("sql: no rows in result set")),
			notFound:    "user not found",
			conflict:    "conflict",
			internal:    "internal failure",
			wantStatus:  http.StatusNotFound,
			wantCode:    "NOT_FOUND",
			wantMessage: "user not found",
			wantCause:   "no rows",
			leak:        "no rows",
		},
		{
			name:        "conflict",
			err:         fmt.Errorf("create user: %w: %w", repository.ErrConflict, errors.New("pq: duplicate key")),
			notFound:    "not found",
			conflict:    "Account already exists",
			internal:    "internal failure",
			wantStatus:  http.StatusConflict,
			wantCode:    "CONFLICT",
			wantMessage: "Account already exists",
			wantCause:   "duplicate key",
			leak:        "duplicate key",
		},
		{
			name:        "unclassified_plain",
			err:         errors.New("boom"),
			notFound:    "not found",
			conflict:    "conflict",
			internal:    "failed to load nearby drivers",
			wantStatus:  http.StatusInternalServerError,
			wantCode:    "INTERNAL",
			wantMessage: "failed to load nearby drivers",
			wantCause:   "boom",
			leak:        "boom",
		},
		{
			name:        "unclassified_driver",
			err:         fmt.Errorf("pq: connection refused: %w", errors.New("driver down")),
			notFound:    "not found",
			conflict:    "conflict",
			internal:    "failed to load nearby drivers",
			wantStatus:  http.StatusInternalServerError,
			wantCode:    "INTERNAL",
			wantMessage: "failed to load nearby drivers",
			wantCause:   "driver down",
			leak:        "driver down",
		},
		{
			name:        "not_found_secret_not_leaked",
			err:         fmt.Errorf("load: %w: %w", repository.ErrNotFound, errors.New("boom secret rows")),
			notFound:    "not found",
			conflict:    "conflict",
			internal:    "internal failure",
			wantStatus:  http.StatusNotFound,
			wantCode:    "NOT_FOUND",
			wantMessage: "not found",
			wantCause:   "boom secret rows",
			leak:        "boom secret",
		},
		{
			name:        "conflict_secret_not_leaked",
			err:         fmt.Errorf("create: %w: %w", repository.ErrConflict, errors.New("boom secret constraint")),
			notFound:    "not found",
			conflict:    "conflict",
			internal:    "internal failure",
			wantStatus:  http.StatusConflict,
			wantCode:    "CONFLICT",
			wantMessage: "conflict",
			wantCause:   "boom secret constraint",
			leak:        "boom secret",
		},
		{
			name:        "internal_secret_not_leaked",
			err:         errors.New("boom secret driver"),
			notFound:    "not found",
			conflict:    "conflict",
			internal:    "internal failure",
			wantStatus:  http.StatusInternalServerError,
			wantCode:    "INTERNAL",
			wantMessage: "internal failure",
			wantCause:   "boom secret driver",
			leak:        "boom secret",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, w := newTestContext()
			respondRepo(c, tc.err, tc.notFound, tc.conflict, tc.internal)

			if w.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d", w.Code, tc.wantStatus)
			}
			var resp ErrorResponse
			if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
				t.Fatalf("decode envelope: %v", err)
			}
			if resp.Error.Code != tc.wantCode || resp.Error.Message != tc.wantMessage {
				t.Fatalf("envelope = %+v, want %s / %q", resp.Error, tc.wantCode, tc.wantMessage)
			}
			if strings.Contains(w.Body.String(), tc.leak) {
				t.Fatalf("body leaks cause text %q: %s", tc.leak, w.Body.String())
			}
			if len(c.Errors) == 0 || !strings.Contains(c.Errors[0].Error(), tc.wantCause) {
				t.Fatalf("c.Errors = %v, want a cause containing %q", c.Errors, tc.wantCause)
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

// TestBindJSONValidationErrorUsesPublicLabels pins that validator failures name
// the public label (from the JSON tag map), never the Go struct/field internals.
// (Consolidated from the registerRequest and rideRequest cases.)
func TestBindJSONValidationErrorUsesPublicLabels(t *testing.T) {
	cases := []struct {
		name        string
		body        string
		obj         func() any
		wantMessage string
		leaks       []string
	}{
		{
			name:        "register_missing_email",
			body:        `{"phone":"+15550000004","password":"SecurePass1"}`,
			obj:         func() any { return &registerRequest{} },
			wantMessage: "Invalid Email",
			leaks:       []string{"registerRequest", "PickupLat", "binding", "required"},
		},
		{
			name:        "ride_missing_pickup_lat",
			body:        `{"pickup_lng":-46.6333,"dropoff_lat":-23.561,"dropoff_lng":-46.656}`,
			obj:         func() any { return &rideRequest{} },
			wantMessage: "Pickup latitude",
			leaks:       []string{"PickupLat"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, w := newTestContext()
			c.Request = httptest.NewRequest(http.MethodPost, "/", strings.NewReader(tc.body))
			c.Request.Header.Set("Content-Type", "application/json")

			if bindJSON(c, tc.obj(), "") {
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
			if !strings.Contains(resp.Error.Message, tc.wantMessage) {
				t.Fatalf("message = %q, want it to contain %q", resp.Error.Message, tc.wantMessage)
			}
			for _, leak := range tc.leaks {
				if strings.Contains(resp.Error.Message, leak) {
					t.Fatalf("message leaks validator internals %q: %q", leak, resp.Error.Message)
				}
			}
		})
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
