package tests

import (
	"encoding/json"
	"net/http"
	"testing"
)

func TestRiderMeRequiresRiderRole(t *testing.T) {
	resp := ts.DoRequest("GET", "/api/v1/rider/me", "", nil)
	resp.AssertStatus(t, http.StatusUnauthorized)
}

func TestRiderMeReturnsOwnProfile(t *testing.T) {
	regResp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.me@test.com",
		"phone":    "+6666666666",
		"password": "SecurePass1",
	})
	regResp.AssertStatus(t, http.StatusCreated)

	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.me@test.com",
		"password": "SecurePass1",
	})

	var loginResult struct {
		AccessToken string `json:"access_token"`
		User        struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/rider/me", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "rider.user_id", loginResult.User.ID)
}

func TestRiderUpdateMeAllowsOwnFields(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "update.me@test.com",
		"phone":    "+7777777777",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "update.me@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("PUT", "/api/v1/rider/me", loginResult.AccessToken, map[string]string{
		"first_name": "John",
		"last_name":  "Doe",
	})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "rider.first_name", "John")
}

func TestDriverMeRequiresDriverRole(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.me@test.com",
		"phone":    "+8888888888",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.me@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/driver/me", loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusForbidden)
}

func TestDriverStatusTransitions(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "driver.status@test.com",
		"phone":    "+9999999999",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "driver.status@test.com",
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
		"email":    "driver.status@test.com",
		"password": "SecurePass1",
	})
	var driverLoginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &driverLoginResult)
	token = driverLoginResult.AccessToken

	resp := ts.DoRequest("PUT", "/api/v1/driver/me/status", token, map[string]string{
		"status": "online",
	})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "driver.status", "online")
}

func parseJSON(t *testing.T, data []byte, v interface{}) {
	t.Helper()
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("failed to parse JSON: %v", err)
	}
}
