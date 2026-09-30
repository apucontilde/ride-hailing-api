package tests

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNavigationRoute(t *testing.T) {
	// Use the global ts from setup_test.go
	if ts == nil {
		t.Fatal("test server not initialized")
	}

	t.Run("Valid route", func(t *testing.T) {
		// Register and Login to get a token
		ts.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
			"email":    "rider@example.com",
			"phone":    "123456789",
			"password": "password123",
		})
		ts.LoginAsRider("rider@example.com", "password123")
		token := ts.AuthTokens["rider"]

		fromLat, fromLng := 9.9333, -84.0833 // San Jose, CR
		toLat, toLng := 9.9433, -84.0733

		url := fmt.Sprintf("%s/api/v1/navigation/route?from_lat=%f&from_lng=%f&to_lat=%f&to_lng=%f",
			ts.URL, fromLat, fromLng, toLat, toLng)

		req, _ := http.NewRequest("GET", url, nil)
		req.Header.Set("Authorization", "Bearer "+token)

		resp, err := http.DefaultClient.Do(req)
		assert.NoError(t, err)
		defer func() { _ = resp.Body.Close() }()

		assert.Equal(t, http.StatusOK, resp.StatusCode)

		var result map[string]interface{}
		err = json.NewDecoder(resp.Body).Decode(&result)
		assert.NoError(t, err)

		// Additive elevation fields (api_plans [elevation] stage 01) must always
		// be present — 0/false when elevation routing is off — so the response
		// shape is stable and clients can rely on the keys existing.
		for _, key := range []string{"total_ascent_m", "total_descent_m", "elevation_aware"} {
			assert.Contains(t, result, key)
		}
		assert.Equal(t, float64(0), result["total_ascent_m"])
		assert.Equal(t, float64(0), result["total_descent_m"])
		assert.Equal(t, false, result["elevation_aware"])

		// If DB is empty, result might be empty, but it shouldn't 500.
		// In a real integration test, we'd ensure the road network is populated.
	})

	t.Run("Invalid coordinates", func(t *testing.T) {
		// Register and Login to get a token
		ts.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
			"email":    "rider2@example.com",
			"phone":    "987654321",
			"password": "password123",
		})
		ts.LoginAsRider("rider2@example.com", "password123")
		token := ts.AuthTokens["rider"]

		url := fmt.Sprintf("%s/api/v1/navigation/route?from_lat=abc&from_lng=def", ts.URL)
		req, _ := http.NewRequest("GET", url, nil)
		req.Header.Set("Authorization", "Bearer "+token)

		resp, err := http.DefaultClient.Do(req)
		assert.NoError(t, err)
		defer func() { _ = resp.Body.Close() }()

		// Coordinates are validated: missing/invalid values are a 422.
		assert.Equal(t, http.StatusUnprocessableEntity, resp.StatusCode)
	})
}
