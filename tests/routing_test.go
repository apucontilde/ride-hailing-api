package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/internal/model"
)

func TestNavigationRouteReturnsEdgeSequence(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.nav@test.com",
		"phone":    "+2323232323",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.nav@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/navigation/route?from=40.7128,-74.0060&to=40.7580,-73.9855",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "total_distance_m")
	resp.AssertJSONHas(t, "total_duration_s")
}

func TestGeoETA(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.eta@test.com",
		"phone":    "+2424242424",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.eta@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/geo/eta?from=40.7128,-74.0060&to=40.7580,-73.9855",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
}

func TestGeoIsochrone(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.iso@test.com",
		"phone":    "+2525252525",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.iso@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/geo/isochrone?lat=40.7128&lng=-74.0060&duration_s=600",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
}

func TestPlacesAutocomplete(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.places@test.com",
		"phone":    "+2626262626",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.places@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	ts.PlacesRepo.Seed(model.PlaceSeed{
		OSMType:  "node",
		OSMID:    1,
		Name:     "Super Mercado Central",
		Category: "shop",
		Lat:      9.9331,
		Lng:      -84.0796,
	})

	// Valid nearby search returns the seeded place.
	resp := ts.DoRequest("GET", "/api/v1/places/autocomplete?lat=9.93&lng=-84.08&q=super&radius=5000",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "places")
	resp.AssertJSONHas(t, "places.0.name", "Super Mercado Central")

	// Missing lat/lng is a validation error.
	bad := ts.DoRequest("GET", "/api/v1/places/autocomplete?q=super",
		loginResult.AccessToken, nil)
	bad.AssertStatus(t, http.StatusUnprocessableEntity)
}
