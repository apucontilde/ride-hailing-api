package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/tests/testutil"
)

func TestHealthLiveness(t *testing.T) {
	resp := ts.DoRequest("GET", "/health", "", nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "status", "ok")
}

func TestHealthReadiness(t *testing.T) {
	resp := ts.DoRequest("GET", "/health/ready", "", nil)
	resp.AssertJSONHas(t, "checks.database")
}

func TestSOSAlertCreated(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.sos@test.com",
		"phone":    "+2121212121",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.sos@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("POST", "/api/v1/sos", loginResult.AccessToken, map[string]float64{
		"lat": 40.7128,
		"lng": -74.0060,
	})
	resp.AssertStatus(t, http.StatusCreated)
}

func TestFeedbackSubmission(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.fb@test.com",
		"phone":    "+2222222222",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.fb@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("POST", "/api/v1/feedback", loginResult.AccessToken, map[string]string{
		"message": "Great app!",
	})
	resp.AssertStatus(t, http.StatusCreated)
}
