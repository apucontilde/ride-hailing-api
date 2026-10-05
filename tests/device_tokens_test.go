package tests

import (
	"errors"
	"net/http"
	"strings"
	"testing"
)

// loginUserID logs in and returns both the access token and the user id, so a
// test can inspect the in-memory device store under the same id the handler
// reads from the JWT.
func loginUserID(t *testing.T, email string) (token, userID string) {
	t.Helper()
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    email,
		"password": "SecurePass1",
	})
	var login struct {
		AccessToken string `json:"access_token"`
		User        struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	parseJSON(t, loginResp.Body, &login)
	return login.AccessToken, login.User.ID
}

func TestDeviceRegisterPersistsAndUnregisterRevokes(t *testing.T) {
	const email = "push.device@test.com"
	registerAndLogin(t, email, "+5100000001")
	token, userID := loginUserID(t, email)

	resp := ts.DoRequest("POST", "/api/v1/devices", token, map[string]string{
		"token": "tok-device-1", "platform": "android",
	})
	resp.AssertStatus(t, http.StatusCreated)
	resp.AssertJSONHas(t, "device.token", "tok-device-1")

	active, err := ts.DeviceRepo.ListActiveTokens(userID)
	if err != nil {
		t.Fatalf("ListActiveTokens: %v", err)
	}
	if len(active) != 1 || active[0].Token != "tok-device-1" || active[0].Platform != "android" {
		t.Fatalf("persisted tokens = %+v, want one android tok-device-1", active)
	}

	delResp := ts.DoRequest("DELETE", "/api/v1/devices/tok-device-1", token, nil)
	delResp.AssertStatus(t, http.StatusNoContent)

	active, err = ts.DeviceRepo.ListActiveTokens(userID)
	if err != nil {
		t.Fatalf("ListActiveTokens after unregister: %v", err)
	}
	if len(active) != 0 {
		t.Fatalf("active tokens after unregister = %+v, want none", active)
	}
}

func TestDeviceRegisterSameTokenTwiceDoesNotDuplicate(t *testing.T) {
	const email = "push.repeat@test.com"
	registerAndLogin(t, email, "+5100000002")
	token, userID := loginUserID(t, email)

	for i := 0; i < 2; i++ {
		resp := ts.DoRequest("POST", "/api/v1/devices", token, map[string]string{
			"token": "tok-repeat", "platform": "ios",
		})
		resp.AssertStatus(t, http.StatusCreated)
	}

	active, err := ts.DeviceRepo.ListActiveTokens(userID)
	if err != nil {
		t.Fatalf("ListActiveTokens: %v", err)
	}
	if len(active) != 1 {
		t.Fatalf("active tokens = %d, want exactly 1 after a re-register", len(active))
	}
}

// TestDeviceTokenReassignmentStopsDeliveringToPreviousOwner is the cross-user
// rule: a token is globally unique, so when the same device registers under a
// different account it must move. The previous owner being empty is what makes
// "token registered for A is not delivered to B" hold at the store.
func TestDeviceTokenReassignmentStopsDeliveringToPreviousOwner(t *testing.T) {
	const riderEmail = "push.reassign.rider@test.com"
	const driverEmail = "push.reassign.driver@test.com"
	registerAndLogin(t, riderEmail, "+5100000003")
	riderToken, riderID := loginUserID(t, riderEmail)
	driverToken := registerDriver(t, driverEmail, "+5100000004")
	_, driverID := loginUserID(t, driverEmail)

	shared := "tok-shared-device"
	ts.DoRequest("POST", "/api/v1/devices", riderToken, map[string]string{
		"token": shared, "platform": "android",
	}).AssertStatus(t, http.StatusCreated)

	// The same device signs in as the driver.
	ts.DoRequest("POST", "/api/v1/devices", driverToken, map[string]string{
		"token": shared, "platform": "android",
	}).AssertStatus(t, http.StatusCreated)

	riderTokens, err := ts.DeviceRepo.ListActiveTokens(riderID)
	if err != nil {
		t.Fatalf("ListActiveTokens(rider): %v", err)
	}
	if len(riderTokens) != 0 {
		t.Fatalf("rider still has %+v, want none after the token moved", riderTokens)
	}
	driverTokens, err := ts.DeviceRepo.ListActiveTokens(driverID)
	if err != nil {
		t.Fatalf("ListActiveTokens(driver): %v", err)
	}
	if len(driverTokens) != 1 || driverTokens[0].Token != shared {
		t.Fatalf("driver tokens = %+v, want the reassigned token", driverTokens)
	}
}

func TestDeviceRegisterValidationErrors(t *testing.T) {
	const email = "push.validation@test.com"
	registerAndLogin(t, email, "+5100000005")
	token, _ := loginUserID(t, email)

	tests := []struct {
		name string
		body map[string]string
	}{
		{name: "missing token", body: map[string]string{"platform": "android"}},
		{name: "missing platform", body: map[string]string{"token": "t"}},
		{name: "invalid platform", body: map[string]string{"token": "t", "platform": "blackberry"}},
		{name: "empty body", body: map[string]string{}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resp := ts.DoRequest("POST", "/api/v1/devices", token, tt.body)
			resp.AssertStatus(t, http.StatusUnprocessableEntity)
			if !strings.Contains(string(resp.Body), "VALIDATION_ERROR") {
				t.Fatalf("body = %s, want a VALIDATION_ERROR envelope", resp.Body)
			}
		})
	}
}

func TestDeviceUnregisterIsIdempotent(t *testing.T) {
	const email = "push.unreg@test.com"
	registerAndLogin(t, email, "+5100000006")
	token, _ := loginUserID(t, email)

	// Unregistering a token that was never registered is a 204 no-op.
	ts.DoRequest("DELETE", "/api/v1/devices/never-there", token, nil).AssertStatus(t, http.StatusNoContent)

	ts.DoRequest("POST", "/api/v1/devices", token, map[string]string{
		"token": "tok-idem", "platform": "web",
	}).AssertStatus(t, http.StatusCreated)
	ts.DoRequest("DELETE", "/api/v1/devices/tok-idem", token, nil).AssertStatus(t, http.StatusNoContent)
	ts.DoRequest("DELETE", "/api/v1/devices/tok-idem", token, nil).AssertStatus(t, http.StatusNoContent)
}

// TestDeviceTokenAliasPath covers the /device-tokens alias sharing the handler.
func TestDeviceTokenAliasPath(t *testing.T) {
	const email = "push.alias@test.com"
	registerAndLogin(t, email, "+5100000007")
	token, userID := loginUserID(t, email)

	ts.DoRequest("POST", "/api/v1/device-tokens", token, map[string]string{
		"token": "tok-alias", "platform": "android",
	}).AssertStatus(t, http.StatusCreated)
	active, err := ts.DeviceRepo.ListActiveTokens(userID)
	if err != nil {
		t.Fatalf("ListActiveTokens: %v", err)
	}
	if len(active) != 1 || active[0].Token != "tok-alias" {
		t.Fatalf("active tokens = %+v, want tok-alias", active)
	}

	ts.DoRequest("DELETE", "/api/v1/device-tokens/tok-alias", token, nil).AssertStatus(t, http.StatusNoContent)
	active, err = ts.DeviceRepo.ListActiveTokens(userID)
	if err != nil {
		t.Fatalf("ListActiveTokens after delete: %v", err)
	}
	if len(active) != 0 {
		t.Fatalf("active tokens = %+v, want none", active)
	}
}

func TestDeviceRegisterWriteFailureIs500(t *testing.T) {
	const email = "push.outage@test.com"
	registerAndLogin(t, email, "+5100000008")
	token, _ := loginUserID(t, email)

	ts.DeviceRepo.FailNextRegister = errors.New("pq: connection reset by peer")

	resp := ts.DoRequest("POST", "/api/v1/devices", token, map[string]string{
		"token": "tok-outage", "platform": "android",
	})
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to register device") {
		t.Fatalf("body = %s, want the operation sentence", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") {
		t.Fatalf("body leaks the driver error: %s", resp.Body)
	}
}
