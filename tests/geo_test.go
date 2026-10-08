package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/tests/testutil"
)

func TestGeoDriverLocationUpsert(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.geo@test.com",
		"phone":    "+1818181818",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.geo@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", token, nil).AssertStatus(t, http.StatusCreated)

	// Re-login after driver registration to get a JWT with role="driver"
	loginResp = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.geo@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token = loginResult.AccessToken

	resp := ts.DoRequest("PUT", "/api/v1/geo/driver/location", token, map[string]float64{
		"lat":     40.7128,
		"lng":     -74.0060,
		"heading": 270,
		"speed":   8.5,
	})
	resp.AssertStatus(t, http.StatusNoContent)
}

func TestGeoDriverLocationRejectsOutOfRange(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.bad@test.com",
		"phone":    "+1919191919",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.bad@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", token, nil)

	// Re-login after driver registration to get a JWT with role="driver"
	loginResp = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.bad@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, loginResp.Body, &loginResult)
	token = loginResult.AccessToken

	resp := ts.DoRequest("PUT", "/api/v1/geo/driver/location", token, map[string]float64{
		"lat": 100.0,
		"lng": 200.0,
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestGeoNearbyDriversExcludesOffline(t *testing.T) {
	// Coordinates away from every other test's drivers, so the nearby query
	// sees only what this test seeds (the shared server keeps mock state).
	const (
		onlineLat = 41.0
		onlineLng = -74.0
	)

	// Online driver: register, go online, push a fresh fix.
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.online@test.com",
		"phone":    "+4141414141",
		"password": "SecurePass1",
	}).AssertStatus(t, http.StatusCreated)
	login1 := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.online@test.com",
		"password": "SecurePass1",
	})
	var tok1 struct {
		AccessToken string `json:"access_token"`
		User        struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	testutil.ParseJSON(t, login1.Body, &tok1)
	ts.DoRequest("POST", "/api/v1/driver/register", tok1.AccessToken, nil).AssertStatus(t, http.StatusCreated)
	login1 = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.online@test.com",
		"password": "SecurePass1",
	})
	testutil.ParseJSON(t, login1.Body, &tok1)
	ts.DoRequest("PUT", "/api/v1/driver/me/status", tok1.AccessToken, map[string]string{
		"status": "online",
	}).AssertStatus(t, http.StatusOK)
	ts.DoRequest("PUT", "/api/v1/geo/driver/location", tok1.AccessToken, map[string]float64{
		"lat": onlineLat, "lng": onlineLng, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	// An actually-offline driver that DOES have a position row. The location
	// endpoint always records a push as "online", so seed the offline row
	// directly; this is the only way to reach the offline-with-a-row state that
	// FindNearbyDrivers must filter out.
	if err := ts.GeoRepo.UpsertDriverPosition("offline-driver-row", onlineLat-0.0005, onlineLng+0.0005, 0, 0, "offline"); err != nil {
		t.Fatalf("seeding the offline driver row: %v", err)
	}

	// Rider to query nearby drivers.
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.nearby@test.com",
		"phone":    "+4343434343",
		"password": "SecurePass1",
	}).AssertStatus(t, http.StatusCreated)
	riderLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.nearby@test.com",
		"password": "SecurePass1",
	})
	var riderTok struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, riderLogin.Body, &riderTok)

	resp := ts.DoRequest("GET", "/api/v1/geo/nearby-drivers?lat=41.0&lng=-74.0&radius=5000&limit=10", riderTok.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)

	var body struct {
		Drivers []struct {
			DriverID string `json:"driver_id"`
		} `json:"drivers"`
	}
	testutil.ParseJSON(t, resp.Body, &body)
	if len(body.Drivers) != 1 {
		t.Fatalf("nearby drivers = %d (%+v), want exactly the 1 online driver", len(body.Drivers), body.Drivers)
	}
	if body.Drivers[0].DriverID != tok1.User.ID {
		t.Errorf("driver_id = %q, want the online driver %q (the offline row must be excluded)",
			body.Drivers[0].DriverID, tok1.User.ID)
	}
}

func TestGeoNearbyDriversRejectsMissingParams(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.nogeo@test.com",
		"phone":    "+2020202020",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.nogeo@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/geo/nearby-drivers", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}
