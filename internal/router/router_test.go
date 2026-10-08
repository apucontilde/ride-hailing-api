package router

import (
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"strings"
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
	found := false
	for _, part := range strings.Split(allow, ",") {
		if strings.EqualFold(textproto.TrimString(part), "Idempotency-Key") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("Access-Control-Allow-Headers %q missing Idempotency-Key", allow)
	}
}
