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

	resp := ts.DoRequest("GET", "/api/v1/navigation/route?from_lat=40.7128&from_lng=-74.0060&to_lat=40.7580&to_lng=-73.9855",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "total_distance_m")
	resp.AssertJSONHas(t, "total_duration_s")
	resp.AssertJSONHas(t, "polyline")

	// Missing coordinates are a validation error, not a silent fallback.
	bad := ts.DoRequest("GET", "/api/v1/navigation/route?from_lat=40.7128&from_lng=-74.0060",
		loginResult.AccessToken, nil)
	bad.AssertStatus(t, http.StatusUnprocessableEntity)
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

	// Route-based ETA from the live engine (mock route: 5000 m / 454 s).
	resp := ts.DoRequest("GET", "/api/v1/geo/eta?from_lat=40.7128&from_lng=-74.0060&to_lat=40.7580&to_lng=-73.9855",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "eta_seconds", float64(454))
	resp.AssertJSONHas(t, "distance_meters", float64(5000))

	// Missing coordinates are a validation error.
	bad := ts.DoRequest("GET", "/api/v1/geo/eta?from_lat=40.7128",
		loginResult.AccessToken, nil)
	bad.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestEstimates(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.est@test.com",
		"phone":    "+2828282828",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.est@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	// Price quotes for all vehicle types, computed from the fare engine.
	price := ts.DoRequest("GET", "/api/v1/estimates/price?pickup_lat=40.7128&pickup_lng=-74.0060&dropoff_lat=40.7580&dropoff_lng=-73.9855",
		loginResult.AccessToken, nil)
	price.AssertStatus(t, http.StatusOK)
	var priceResult struct {
		Estimates []struct {
			VehicleType string  `json:"vehicle_type"`
			Total       float64 `json:"total"`
		} `json:"estimates"`
	}
	parseJSON(t, price.Body, &priceResult)
	if len(priceResult.Estimates) != 3 {
		t.Errorf("expected 3 estimates, got %d", len(priceResult.Estimates))
	}
	if priceResult.Estimates[0].VehicleType != "sedan" {
		t.Errorf("expected first estimate sedan, got %s", priceResult.Estimates[0].VehicleType)
	}
	if priceResult.Estimates[0].Total <= 0 {
		t.Errorf("expected a positive total, got %f", priceResult.Estimates[0].Total)
	}

	// A single vehicle_type limits the quote to one entry.
	single := ts.DoRequest("GET", "/api/v1/estimates/price?pickup_lat=40.7128&pickup_lng=-74.0060&dropoff_lat=40.7580&dropoff_lng=-73.9855&vehicle_type=suv",
		loginResult.AccessToken, nil)
	single.AssertStatus(t, http.StatusOK)
	var singleResult struct {
		Estimates []struct {
			VehicleType string `json:"vehicle_type"`
		} `json:"estimates"`
	}
	parseJSON(t, single.Body, &singleResult)
	if len(singleResult.Estimates) != 1 || singleResult.Estimates[0].VehicleType != "suv" {
		t.Errorf("expected single suv estimate, got %+v", singleResult.Estimates)
	}

	// Unknown vehicle type and missing coords are validation errors.
	badVT := ts.DoRequest("GET", "/api/v1/estimates/price?pickup_lat=40.7128&pickup_lng=-74.0060&dropoff_lat=40.7580&dropoff_lng=-73.9855&vehicle_type=helicopter",
		loginResult.AccessToken, nil)
	badVT.AssertStatus(t, http.StatusUnprocessableEntity)
	badCoords := ts.DoRequest("GET", "/api/v1/estimates/price?pickup_lat=40.7128",
		loginResult.AccessToken, nil)
	badCoords.AssertStatus(t, http.StatusUnprocessableEntity)

	// Trip ETA before booking, from the same routing engine (US-4).
	eta := ts.DoRequest("GET", "/api/v1/estimates/eta?from_lat=40.7128&from_lng=-74.0060&to_lat=40.7580&to_lng=-73.9855",
		loginResult.AccessToken, nil)
	eta.AssertStatus(t, http.StatusOK)
	eta.AssertJSONHas(t, "eta_seconds", float64(454))
	eta.AssertJSONHas(t, "distance_meters", float64(5000))
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

func TestPlacesGeocode(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.geo@test.com",
		"phone":    "+2727272727",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.geo@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	addr := "Av. Central, San José"
	ts.PlacesRepo.Seed(model.PlaceSeed{
		OSMType:  "node",
		OSMID:    2,
		Name:     "Museo Nacional",
		Category: "tourism",
		Address:  &addr,
		Lat:      9.98,
		Lng:      -84.05,
	})

	// A pin on top of the place returns it as the nearest match.
	resp := ts.DoRequest("GET", "/api/v1/places/geocode?lat=9.98&lng=-84.05",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "place.name", "Museo Nacional")
	resp.AssertJSONHas(t, "place.address", addr)

	// A pin with no place within the (default 500m) radius yields a null place.
	far := ts.DoRequest("GET", "/api/v1/places/geocode?lat=9.95&lng=-84.10",
		loginResult.AccessToken, nil)
	far.AssertStatus(t, http.StatusOK)
	far.AssertJSONHas(t, "place")
	far.AssertJSONMissing(t, "place.name")

	// Missing/invalid lat is a validation error.
	bad := ts.DoRequest("GET", "/api/v1/places/geocode?lng=-84.08",
		loginResult.AccessToken, nil)
	bad.AssertStatus(t, http.StatusUnprocessableEntity)

	// An explicit radius rescues a pin just outside the default 500m radius
	// (~0.005deg lat offset from the place ≈ 555m away).
	out := ts.DoRequest("GET", "/api/v1/places/geocode?lat=9.9850&lng=-84.05&radius=2000",
		loginResult.AccessToken, nil)
	out.AssertStatus(t, http.StatusOK)
	out.AssertJSONHas(t, "place.name", "Museo Nacional")
}
