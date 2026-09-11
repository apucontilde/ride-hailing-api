package router

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
)

func TestCorsAllowsIdempotencyKey(t *testing.T) {
	r := SetupWithRepos(&config.Config{}, nil, nil, nil, nil, nil, (*sqlx.DB)(nil))

	req := httptest.NewRequest(http.MethodOptions, "/api/v1/rides", nil)
	req.Header.Set("Origin", "http://localhost:5555")
	req.Header.Set("Access-Control-Request-Method", http.MethodPost)
	req.Header.Set("Access-Control-Request-Headers", "content-type,authorization,idempotency-key")

	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent && w.Code != http.StatusOK {
		t.Fatalf("expected preflight to pass, got %d", w.Code)
	}

	allow := w.Header().Get("Access-Control-Allow-Headers")
	if allow == "" {
		t.Fatalf("expected Access-Control-Allow-Headers header")
	}
	if !containsHeader(allow, "Idempotency-Key") {
		t.Fatalf("Access-Control-Allow-Headers %q missing Idempotency-Key", allow)
	}
}

func containsHeader(value, wanted string) bool {
	for _, part := range splitHeaders(value) {
		if part == wanted {
			return true
		}
	}
	return false
}

func splitHeaders(value string) []string {
	var parts []string
	start := 0
	for i := 0; i <= len(value); i++ {
		if i == len(value) || value[i] == ',' {
			part := trimSpace(value[start:i])
			if part != "" {
				parts = append(parts, part)
			}
			start = i + 1
		}
	}
	return parts
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}
