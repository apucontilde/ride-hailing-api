package tests

import (
	"net/http"
	"testing"
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
	parseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", token, nil).AssertStatus(t, http.StatusCreated)

	// Re-login after driver registration to get a JWT with role="driver"
	loginResp = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.geo@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, loginResp.Body, &loginResult)
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
	parseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", token, nil)

	// Re-login after driver registration to get a JWT with role="driver"
	loginResp = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.bad@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, loginResp.Body, &loginResult)
	token = loginResult.AccessToken

	resp := ts.DoRequest("PUT", "/api/v1/geo/driver/location", token, map[string]float64{
		"lat": 100.0,
		"lng": 200.0,
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestGeoNearbyDriversExcludesOffline(t *testing.T) {
	// Create online driver — register, login, set location
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
	}
	parseJSON(t, login1.Body, &tok1)
	ts.DoRequest("POST", "/api/v1/driver/register", tok1.AccessToken, nil).AssertStatus(t, http.StatusCreated)
	login1 = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.online@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, login1.Body, &tok1)
	ts.DoRequest("PUT", "/api/v1/geo/driver/location", tok1.AccessToken, map[string]float64{
		"lat": 40.71, "lng": -74.00, "heading": 0, "speed": 0,
	}).AssertStatus(t, http.StatusNoContent)

	// Create offline driver — register but never set location
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.offline@test.com",
		"phone":    "+4242424242",
		"password": "SecurePass1",
	}).AssertStatus(t, http.StatusCreated)
	login2 := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.offline@test.com",
		"password": "SecurePass1",
	})
	var tok2 struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, login2.Body, &tok2)
	ts.DoRequest("POST", "/api/v1/driver/register", tok2.AccessToken, nil).AssertStatus(t, http.StatusCreated)

	// Create a rider to query nearby drivers
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
	parseJSON(t, riderLogin.Body, &riderTok)

	// Query nearby drivers — only online driver should appear
	resp := ts.DoRequest("GET", "/api/v1/geo/nearby-drivers?lat=40.71&lng=-74.00&radius=5000&limit=10", riderTok.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "drivers")
	resp.AssertJSONHas(t, "drivers.0.driver_id")
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
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/geo/nearby-drivers", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}
