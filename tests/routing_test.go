package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/internal/model"
	"ride-hailing-api/tests/testutil"
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
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

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

// TestGeoETA asserts against the navigation MOCK's fixture, not a road
// network: MockNavigationRepo returns a two-node path with an aggregated edge
// cost of 5000 m, and the handler derives duration = distance / 11 m/s = 454 s.
// Those constants live in tests/testutil/mock_navigation_repo.go:16.
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
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

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

// TestEstimates' 5000 m / 454 s expectations come from the same
// MockNavigationRepo fixture (tests/testutil/mock_navigation_repo.go:16). They
// pin that the fare/estimate layer consumes the routed distance, not that real
// road data is present.
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
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

	// Price quotes for all vehicle types, computed from the fare engine. The
	// endpoint is POST with a JSON body (api_plans/[fare]_waypoint_fare.md §4).
	priceBody := map[string]interface{}{
		"pickup_lat": 40.7128, "pickup_lng": -74.0060,
		"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
	}
	price := ts.DoRequest("POST", "/api/v1/estimates/price", loginResult.AccessToken, priceBody)
	price.AssertStatus(t, http.StatusOK)
	var priceResult struct {
		Estimates []struct {
			VehicleType string  `json:"vehicle_type"`
			Total       float64 `json:"total"`
			IsEstimate  bool    `json:"is_estimate"`
			Legs        []struct {
				DistanceM   int     `json:"distance_m"`
				DurationS   int     `json:"duration_s"`
				DistanceFee float64 `json:"distance_fare"`
				TimeFee     float64 `json:"time_fare"`
			} `json:"legs"`
		} `json:"estimates"`
	}
	testutil.ParseJSON(t, price.Body, &priceResult)
	if len(priceResult.Estimates) != 3 {
		t.Errorf("expected 3 estimates, got %d", len(priceResult.Estimates))
	}
	if priceResult.Estimates[0].VehicleType != "sedan" {
		t.Errorf("expected first estimate sedan, got %s", priceResult.Estimates[0].VehicleType)
	}
	if priceResult.Estimates[0].Total <= 0 {
		t.Errorf("expected a positive total, got %f", priceResult.Estimates[0].Total)
	}
	// A zero-stop request still carries the additive fields: is_estimate false
	// and exactly one leg equal to the whole trip.
	if priceResult.Estimates[0].IsEstimate {
		t.Error("a covered mock route must not be flagged is_estimate")
	}
	if len(priceResult.Estimates[0].Legs) != 1 || priceResult.Estimates[0].Legs[0].DistanceM != 5000 {
		t.Errorf("zero-stop legs = %+v, want one leg of 5000 m", priceResult.Estimates[0].Legs)
	}

	// A single vehicle_type limits the quote to one entry.
	singleBody := map[string]interface{}{
		"pickup_lat": 40.7128, "pickup_lng": -74.0060,
		"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
		"vehicle_type": "suv",
	}
	single := ts.DoRequest("POST", "/api/v1/estimates/price", loginResult.AccessToken, singleBody)
	single.AssertStatus(t, http.StatusOK)
	var singleResult struct {
		Estimates []struct {
			VehicleType string `json:"vehicle_type"`
		} `json:"estimates"`
	}
	testutil.ParseJSON(t, single.Body, &singleResult)
	if len(singleResult.Estimates) != 1 || singleResult.Estimates[0].VehicleType != "suv" {
		t.Errorf("expected single suv estimate, got %+v", singleResult.Estimates)
	}

	// Unknown vehicle type and missing coords are validation errors.
	badVT := ts.DoRequest("POST", "/api/v1/estimates/price", loginResult.AccessToken,
		map[string]interface{}{
			"pickup_lat": 40.7128, "pickup_lng": -74.0060,
			"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
			"vehicle_type": "helicopter",
		})
	badVT.AssertStatus(t, http.StatusUnprocessableEntity)
	badCoords := ts.DoRequest("POST", "/api/v1/estimates/price", loginResult.AccessToken,
		map[string]interface{}{"pickup_lat": 40.7128})
	badCoords.AssertStatus(t, http.StatusUnprocessableEntity)

	// The GET route is gone (hard cutover, no alias): a stale GET is a 404.
	getGone := ts.DoRequest("GET", "/api/v1/estimates/price?pickup_lat=40.7128&pickup_lng=-74.0060&dropoff_lat=40.7580&dropoff_lng=-73.9855",
		loginResult.AccessToken, nil)
	getGone.AssertStatus(t, http.StatusNotFound)

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
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

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
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

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
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

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
