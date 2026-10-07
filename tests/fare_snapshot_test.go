package tests

import (
	"net/http"
	"testing"
)

// TestRideSnapshotsFareCard proves the created ride records WHICH card priced
// it (api_plans/STATUS.md [fare]). The db-less harness seeds the
// default region cr-sj, and the mock navigation repo takes the legacy path
// (no resolved region), so the documented default-region fallback is what
// prices this ride.
func TestRideSnapshotsFareCard(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.faresnap@test.com",
		"phone":    "+1999000001",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.faresnap@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	createResp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.006,
		"dropoff_lat": 40.758,
		"dropoff_lng": -73.9855,
	})
	createResp.AssertStatus(t, http.StatusCreated)
	createResp.AssertJSONHas(t, "ride.fare_region_id", "cr-sj")
	createResp.AssertJSONHas(t, "ride.fare_currency", "USD")
	createResp.AssertJSONHas(t, "ride.fare_rate_id")

	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	receipt := ts.DoRequest("GET", "/api/v1/rides/"+createResult.Ride.ID+"/receipt", loginResult.AccessToken, nil)
	receipt.AssertStatus(t, http.StatusOK)
	receipt.AssertJSONHas(t, "receipt.region_id", "cr-sj")
	receipt.AssertJSONHas(t, "receipt.currency", "USD")
}

// TestEstimateCarriesRegionAndCurrency proves the additive pricing fields on
// GET /estimates/price: an estimate still prices, and it names the region and
// currency it used.
func TestEstimateCarriesRegionAndCurrency(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.estfares@test.com",
		"phone":    "+1999000002",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.estfares@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET",
		"/api/v1/estimates/price?pickup_lat=40.7128&pickup_lng=-74.006&dropoff_lat=40.758&dropoff_lng=-73.9855&vehicle_type=sedan",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "estimates.0.region_id", "cr-sj")
	resp.AssertJSONHas(t, "estimates.0.currency", "USD")
	resp.AssertJSONHas(t, "estimates.0.total")
}
