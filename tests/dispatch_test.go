package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/tests/testutil"
)

func TestDriverRideQueue(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.queue@test.com",
		"phone":    "+2626262626",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.queue@test.com",
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
		"email":    "driver.queue@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, loginResp.Body, &loginResult)
	token = loginResult.AccessToken

	resp := ts.DoRequest("GET", "/api/v1/driver/rides/queue", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "queue")
}

func TestDriverAcceptRide(t *testing.T) {
	riderReg := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.dispatch@test.com",
		"phone":    "+2727272727",
		"password": "SecurePass1",
	})
	riderReg.AssertStatus(t, http.StatusCreated)

	riderLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.dispatch@test.com",
		"password": "SecurePass1",
	})
	var riderLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, riderLogin.Body, &riderLoginResult)
	riderToken := riderLoginResult.AccessToken

	driverReg := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.dispatch@test.com",
		"phone":    "+2828282828",
		"password": "SecurePass1",
	})
	driverReg.AssertStatus(t, http.StatusCreated)

	driverLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.dispatch@test.com",
		"password": "SecurePass1",
	})
	var driverLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken := driverLoginResult.AccessToken

	ts.DoRequest("POST", "/api/v1/driver/register", driverToken, nil)

	// Re-login after driver registration to get a JWT with role="driver"
	driverLogin = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.dispatch@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, driverLogin.Body, &driverLoginResult)
	driverToken = driverLoginResult.AccessToken

	conn := ts.DialWS(t, riderToken)
	defer conn.Close()

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	createResp.AssertStatus(t, http.StatusCreated)

	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	// Consume the "pending" push from ride creation
	testutil.ReadWSMessage(t, conn)

	acceptResp := ts.DoRequest("POST", "/api/v1/driver/rides/"+createResult.Ride.ID+"/accept", driverToken, nil)
	acceptResp.AssertStatus(t, http.StatusOK)

	msg := testutil.ReadWSMessage(t, conn)
	if msg["type"] != "ride.updated" {
		t.Errorf("expected type 'ride.updated', got %v", msg["type"])
	}
	data := msg["data"].(map[string]interface{})
	if data["status"] != "accepted" {
		t.Errorf("expected status 'accepted', got %v", data["status"])
	}
}

func TestDriverAcceptAlreadyTaken(t *testing.T) {
	riderReg := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.taken@test.com",
		"phone":    "+2929292929",
		"password": "SecurePass1",
	})
	riderReg.AssertStatus(t, http.StatusCreated)

	riderLogin := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.taken@test.com",
		"password": "SecurePass1",
	})
	var riderLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, riderLogin.Body, &riderLoginResult)

	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.taken1@test.com",
		"phone":    "+3030303030",
		"password": "SecurePass1",
	})
	driver1Login := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.taken1@test.com",
		"password": "SecurePass1",
	})
	var driver1LoginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, driver1Login.Body, &driver1LoginResult)
	driver1Token := driver1LoginResult.AccessToken
	ts.DoRequest("POST", "/api/v1/driver/register", driver1Token, nil)

	// Re-login after driver registration to get a JWT with role="driver"
	driver1Login = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.taken1@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, driver1Login.Body, &driver1LoginResult)
	driver1Token = driver1LoginResult.AccessToken

	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.taken2@test.com",
		"phone":    "+3131313131",
		"password": "SecurePass1",
	})
	driver2Login := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.taken2@test.com",
		"password": "SecurePass1",
	})
	var driver2LoginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, driver2Login.Body, &driver2LoginResult)
	driver2Token := driver2LoginResult.AccessToken
	ts.DoRequest("POST", "/api/v1/driver/register", driver2Token, nil)

	// Re-login after driver registration to get a JWT with role="driver"
	driver2Login = ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.taken2@test.com",
		"password": "SecurePass1",
	})
	parseJSON(t, driver2Login.Body, &driver2LoginResult)
	driver2Token = driver2LoginResult.AccessToken

	createResp := ts.DoRequest("POST", "/api/v1/rides", riderLoginResult.AccessToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)
	rideID := createResult.Ride.ID

	ts.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driver1Token, nil).AssertStatus(t, http.StatusOK)

	secondAccept := ts.DoRequest("POST", "/api/v1/driver/rides/"+rideID+"/accept", driver2Token, nil)
	secondAccept.AssertStatus(t, http.StatusConflict)
}
