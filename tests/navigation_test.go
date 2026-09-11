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
		defer resp.Body.Close()

		assert.Equal(t, http.StatusOK, resp.StatusCode)

		var result struct {
			Polyline       []map[string]float64 `json:"polyline"`
			TotalDistanceM int                  `json:"total_distance_m"`
			TotalDurationS int                  `json:"total_duration_s"`
		}
		err = json.NewDecoder(resp.Body).Decode(&result)
		assert.NoError(t, err)

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
		defer resp.Body.Close()

		// Coordinates are validated: missing/invalid values are a 422.
		assert.Equal(t, http.StatusUnprocessableEntity, resp.StatusCode)
	})
}
