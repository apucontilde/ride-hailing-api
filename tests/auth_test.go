package tests

import (
	"net/http"
	"testing"
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
