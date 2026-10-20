package handler_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"ride-hailing-api/internal/handler"
	"ride-hailing-api/internal/websocket"
	"ride-hailing-api/tests/testutil"
)

// TestDriverLocationJSONShapeHasNoFreshnessFields is the regression pin for
// api_plans/[arrival]_accept_time_evaluation.md D6=B: NearbyDriverResult gained
// UpdatedAt and AgeS for the accept-time gate, but GET
// /api/v1/drivers/:id/location marshals that struct directly, so both must stay
// json:"-" and the public response shape must not gain updated_at/age_s.
func TestDriverLocationJSONShapeHasNoFreshnessFields(t *testing.T) {
	gin.SetMode(gin.TestMode)

	geoRepo := testutil.NewMockGeoRepo()
	if err := geoRepo.UpsertDriverPosition("driver-shape", 9.93, -84.08, 90, 5, "online"); err != nil {
		t.Fatalf("seed driver position: %v", err)
	}
	h := handler.NewGeoHandler(geoRepo, testutil.NewMockRideRepo(), websocket.NewHub(), nil)

	r := gin.New()
	r.GET("/api/v1/drivers/:id/location", h.GetDriverLocation)

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/drivers/driver-shape/location", nil)
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (body=%s)", w.Code, w.Body.String())
	}

	var body map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode location body: %v (body=%s)", err, w.Body.String())
	}
	for _, key := range []string{"updated_at", "age_s"} {
		if _, ok := body[key]; ok {
			t.Errorf("GET driver location gained %q: %v", key, body)
		}
	}
	if body["lat"] != 9.93 || body["lng"] != -84.08 {
		t.Errorf("lat/lng = %v/%v, want the seeded fix", body["lat"], body["lng"])
	}
}
