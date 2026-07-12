package tests

import (
	"net/http"
	"testing"
)

func TestRideRequestCreatesPending(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.ride@test.com",
		"phone":    "+1010101010",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.ride@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	resp.AssertStatus(t, http.StatusCreated)
	resp.AssertJSONHas(t, "ride.status", "pending")
	resp.AssertJSONHas(t, "ride.id")
}

func TestRideCancelBeforeAccept(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.cancel@test.com",
		"phone":    "+1212121212",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.cancel@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)
	token := loginResult.AccessToken

	createResp := ts.DoRequest("POST", "/api/v1/rides", token, map[string]float64{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	})
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	resp := ts.DoRequest("POST", "/api/v1/rides/"+createResult.Ride.ID+"/cancel", token, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "ride.status", "cancelled")
}

func TestRideCurrentReturnsNullWhenIdle(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.idle@test.com",
		"phone":    "+1313131313",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.idle@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/rides/current", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "ride")
}

func TestRideRequestRejectsMissingFields(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.missing@test.com",
		"phone":    "+1414141414",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.missing@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("POST", "/api/v1/rides", loginResult.AccessToken, map[string]string{
		"pickup_lat": "invalid",
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestRideHistoryPagination(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.pages@test.com",
		"phone":    "+1515151515",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.pages@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/rides/history?page=1&per_page=10", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "total")
	resp.AssertJSONHas(t, "page", float64(1))
}

func TestRideTipStub(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.tip@test.com",
		"phone":    "+1616161616",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.tip@test.com",
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
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	resp := ts.DoRequest("POST", "/api/v1/rides/"+createResult.Ride.ID+"/tip", loginResult.AccessToken, map[string]float64{"amount": 5.0})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "status", "stub")
}

func TestRideReceipt(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.receipt@test.com",
		"phone":    "+1717171717",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.receipt@test.com",
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
	var createResult struct {
		Ride struct{ ID string } `json:"ride"`
	}
	parseJSON(t, createResp.Body, &createResult)

	resp := ts.DoRequest("GET", "/api/v1/rides/"+createResult.Ride.ID+"/receipt", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "receipt.base_fare")
}
