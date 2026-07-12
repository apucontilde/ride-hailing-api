package tests

import (
	"net/http"
	"testing"

	"ride-hailing-api/tests/testutil"
)

func TestRegisterCreatesAccount(t *testing.T) {
	resp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider@test.com",
		"phone":    "+1234567890",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusCreated)
	resp.AssertJSONHas(t, "user.id")
	resp.AssertJSONHas(t, "user.email", "rider@test.com")
	resp.AssertJSONHas(t, "user.role", "rider")
	resp.AssertJSONMissing(t, "user.password")
}

func TestRegisterRejectsWeakPassword(t *testing.T) {
	resp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "weak@test.com",
		"phone":    "+1987654321",
		"password": "short",
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestRegisterRejectsDuplicateEmail(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "dup@test.com",
		"phone":    "+1111111111",
		"password": "SecurePass1",
	})

	resp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "dup@test.com",
		"phone":    "+2222222222",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusConflict)
}

func TestLoginReturnsTokens(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "login@test.com",
		"phone":    "+3333333333",
		"password": "SecurePass1",
	})

	resp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "login@test.com",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "access_token")
	resp.AssertJSONHas(t, "refresh_token")
}

func TestLoginRejectsBadPassword(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "badpass@test.com",
		"phone":    "+4444444444",
		"password": "SecurePass1",
	})

	resp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "badpass@test.com",
		"password": "WrongPassword1",
	})
	resp.AssertStatus(t, http.StatusUnauthorized)
}

func TestAuthRequiresToken(t *testing.T) {
	resp := ts.DoRequest("GET", "/api/v1/rider/me", "", nil)
	resp.AssertStatus(t, http.StatusUnauthorized)
}

func TestRegisterRejectsInvalidEmail(t *testing.T) {
	resp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "not-an-email",
		"phone":    "+5555555555",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusUnprocessableEntity)
}

func TestLoginReturnsRefreshToken(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "refreshtest@test.com",
		"phone":    "+6666666666",
		"password": "SecurePass1",
	})

	resp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "refreshtest@test.com",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "refresh_token")

	var loginResult struct {
		RefreshToken string `json:"refresh_token"`
	}
	testutil.ParseJSON(t, resp.Body, &loginResult)

	if loginResult.RefreshToken == "" {
		t.Error("expected non-empty refresh_token")
	}
}

func TestRefreshTokenIssuesNewTokens(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "refreshexchange@test.com",
		"phone":    "+7777777777",
		"password": "SecurePass1",
	})

	loginResp := ts.DoRequest("POST", "/api/v1/auth/login", "", map[string]string{
		"email":    "refreshexchange@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

	refreshResp := ts.DoRequest("POST", "/api/v1/auth/refresh", "", map[string]string{
		"refresh_token": loginResult.RefreshToken,
	})
	refreshResp.AssertStatus(t, http.StatusOK)
	refreshResp.AssertJSONHas(t, "access_token")
	refreshResp.AssertJSONHas(t, "refresh_token")

	var refreshResult struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	testutil.ParseJSON(t, refreshResp.Body, &refreshResult)

	if refreshResult.AccessToken == loginResult.AccessToken {
		t.Error("expected new access_token after refresh")
	}

	oldRefreshResp := ts.DoRequest("POST", "/api/v1/auth/refresh", "", map[string]string{
		"refresh_token": loginResult.RefreshToken,
	})
	oldRefreshResp.AssertStatus(t, http.StatusUnauthorized)
}

func TestForgotPasswordReturnsTokenForExistingEmail(t *testing.T) {
	resp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "forgot@test.com",
		"phone":    "+1111111111",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusCreated)

	forgotResp := ts.DoRequest("POST", "/api/v1/auth/forgot-password", "", map[string]string{
		"email": "forgot@test.com",
	})
	forgotResp.AssertStatus(t, http.StatusOK)
	forgotResp.AssertJSONHas(t, "reset_token")
}

func TestForgotPasswordReturnsOkForUnknownEmail(t *testing.T) {
	forgotResp := ts.DoRequest("POST", "/api/v1/auth/forgot-password", "", map[string]string{
		"email": "nonexistent@test.com",
	})
	forgotResp.AssertStatus(t, http.StatusOK)

	var result map[string]interface{}
	testutil.ParseJSON(t, forgotResp.Body, &result)
	if _, ok := result["reset_token"]; ok {
		t.Error("should not include reset_token for unknown email")
	}
}

func TestResetPasswordWithValidToken(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "resetok@test.com",
		"phone":    "+2222222222",
		"password": "OldPass1",
	})

	forgotResp := ts.DoRequest("POST", "/api/v1/auth/forgot-password", "", map[string]string{
		"email": "resetok@test.com",
	})
	var forgotResult struct {
		ResetToken string `json:"reset_token"`
	}
	testutil.ParseJSON(t, forgotResp.Body, &forgotResult)

	resetResp := ts.DoRequest("POST", "/api/v1/auth/reset-password", "", map[string]string{
		"token":       forgotResult.ResetToken,
		"new_password": "NewPass1",
	})
	resetResp.AssertStatus(t, http.StatusOK)

	// Login with new password
	loginResp := ts.DoRequest("POST", "/api/v1/auth/login", "", map[string]string{
		"email":    "resetok@test.com",
		"password": "NewPass1",
	})
	loginResp.AssertStatus(t, http.StatusOK)

	// Old password should fail
	oldLoginResp := ts.DoRequest("POST", "/api/v1/auth/login", "", map[string]string{
		"email":    "resetok@test.com",
		"password": "OldPass1",
	})
	oldLoginResp.AssertStatus(t, http.StatusUnauthorized)
}

func TestResetPasswordRejectsInvalidToken(t *testing.T) {
	resp := ts.DoRequest("POST", "/api/v1/auth/reset-password", "", map[string]string{
		"token":       "invalid-token",
		"new_password": "NewPass1",
	})
	resp.AssertStatus(t, http.StatusBadRequest)
}

func TestResetPasswordRejectsUsedToken(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "resetused@test.com",
		"phone":    "+3333333333",
		"password": "OldPass1",
	})

	forgotResp := ts.DoRequest("POST", "/api/v1/auth/forgot-password", "", map[string]string{
		"email": "resetused@test.com",
	})
	var forgotResult struct {
		ResetToken string `json:"reset_token"`
	}
	testutil.ParseJSON(t, forgotResp.Body, &forgotResult)

	// First use — should succeed
	ts.DoRequest("POST", "/api/v1/auth/reset-password", "", map[string]string{
		"token":        forgotResult.ResetToken,
		"new_password": "NewPass2",
	}).AssertStatus(t, http.StatusOK)

	// Second use — should fail (already used)
	resp := ts.DoRequest("POST", "/api/v1/auth/reset-password", "", map[string]string{
		"token":        forgotResult.ResetToken,
		"new_password": "AnotherPass3",
	})
	resp.AssertStatus(t, http.StatusBadRequest)
}

func TestLogoutRevokesRefreshToken(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "logouttest@test.com",
		"phone":    "+8888888888",
		"password": "SecurePass1",
	})

	loginResp := ts.DoRequest("POST", "/api/v1/auth/login", "", map[string]string{
		"email":    "logouttest@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &loginResult)

	logoutResp := ts.DoRequest("POST", "/api/v1/auth/logout", loginResult.AccessToken, map[string]string{
		"refresh_token": loginResult.RefreshToken,
	})
	logoutResp.AssertStatus(t, http.StatusOK)

	refreshResp := ts.DoRequest("POST", "/api/v1/auth/refresh", "", map[string]string{
		"refresh_token": loginResult.RefreshToken,
	})
	refreshResp.AssertStatus(t, http.StatusUnauthorized)
}
