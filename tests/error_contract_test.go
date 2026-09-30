package tests

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"

	"ride-hailing-api/tests/testutil"
)

// These tests push the FailNext knobs (api_plans [errors]) to reach the new
// 500 branches: a repository write/revoke failure must answer 500 with the
// operation's own sentence, and the body must never carry the driver error.

func TestRefreshRevokeFailureIs500(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "refresh.outage@test.com",
		"phone":    "+1717171717",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "refresh.outage@test.com",
		"password": "SecurePass1",
	})
	var login struct {
		RefreshToken string `json:"refresh_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &login)

	// The fail-closed revocation must surface as a 500, not a 401.
	ts.UserRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := ts.DoRequest("POST", "/api/v1/auth/refresh", "", map[string]string{
		"refresh_token": login.RefreshToken,
	})
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to refresh token") {
		t.Fatalf("body = %s, want operation sentence 'failed to refresh token'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "connection reset") {
		t.Fatalf("body leaks driver error: %s", resp.Body)
	}
}

func TestResetPasswordRevokeFailureIs500(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "reset.outage@test.com",
		"phone":    "+1818181818",
		"password": "SecurePass1",
	})
	forgotResp := ts.DoRequest("POST", "/api/v1/auth/forgot-password", "", map[string]string{
		"email": "reset.outage@test.com",
	})
	var forgot struct {
		ResetToken string `json:"reset_token"`
	}
	testutil.ParseJSON(t, forgotResp.Body, &forgot)

	ts.UserRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := ts.DoRequest("POST", "/api/v1/auth/reset-password", "", map[string]string{
		"token":        forgot.ResetToken,
		"new_password": "NewPass1",
	})
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to reset password") {
		t.Fatalf("body = %s, want operation sentence 'failed to reset password'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "connection reset") {
		t.Fatalf("body leaks driver error: %s", resp.Body)
	}
}

func TestGeoWriteFailureIs500(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "geo.outage@test.com",
		"phone":    "+1919191919",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "geo.outage@test.com",
		"password": "SecurePass1",
	})
	var login struct {
		AccessToken string `json:"access_token"`
	}
	testutil.ParseJSON(t, loginResp.Body, &login)

	ts.GeoRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := ts.DoRequest("PUT", "/api/v1/geo/rider/location", login.AccessToken, map[string]float64{
		"lat": 40.71, "lng": -74.00,
	})
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to update location") {
		t.Fatalf("body = %s, want operation sentence 'failed to update location'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "connection reset") {
		t.Fatalf("body leaks driver error: %s", resp.Body)
	}
}

func TestLoginDBOutageIs500Not401(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "login.outage@test.com",
		"phone":    "+1515151515",
		"password": "SecurePass1",
	})

	// A read-path driver failure must answer 500 with the operation sentence,
	// not masquerade as a 401 "invalid credentials".
	ts.UserRepo.FailNext = errors.New("pq: connection reset by peer")

	resp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "login.outage@test.com",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusInternalServerError)
	if !strings.Contains(string(resp.Body), "failed to log in") {
		t.Fatalf("body = %s, want operation sentence 'failed to log in'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "connection reset") {
		t.Fatalf("body leaks driver error: %s", resp.Body)
	}
}

func TestLoginUnknownEmailStill401(t *testing.T) {
	// A genuine absent account must remain indistinguishable from a wrong
	// password: 401 with the same public message, no enumeration regression.
	resp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "nobody@test.com",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusUnauthorized)
	if !strings.Contains(string(resp.Body), "invalid credentials") {
		t.Fatalf("body = %s, want 'invalid credentials'", resp.Body)
	}
}

func TestRegisterDuplicateEmailBodyIsStable(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "dup.body@test.com",
		"phone":    "+15550000101",
		"password": "SecurePass1",
	})

	resp := ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "dup.body@test.com",
		"phone":    "+15550000102",
		"password": "SecurePass1",
	})
	resp.AssertStatus(t, http.StatusConflict)
	if !strings.Contains(string(resp.Body), "Account already exists") {
		t.Fatalf("body = %s, want 'Account already exists'", resp.Body)
	}
	if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "users_email_key") {
		t.Fatalf("body leaks schema detail: %s", resp.Body)
	}
}

// TestRouteCalculationFailureIs500Not4xx pins the API half of the
// "confident road-less route" hazard (api_plans/[errors]_route_outage_contract_test.md,
// the chain head the rider/driver route-fallback plans depend on).
//
// Both Flutter apps draw a straight-line fallback on EVERY error status
// (rider_app .../home_screen.dart:157), so a route outage classified as 4xx
// renders a plausible-looking, road-less route. A failed calculation must
// therefore be 5xx — never 4xx — and must carry the house envelope.
func TestRouteCalculationFailureIs500Not4xx(t *testing.T) {
	navOutage := testutil.NewTestServerWithNav(t,
		testutil.NewFailingNavigationRepo(errors.New("pq: could not connect to road_network_edges_pgr")))
	defer navOutage.Close()

	for _, tc := range []struct {
		name string
		path string
	}{
		{"navigation route", "/api/v1/navigation/route?from_lat=9.9333&from_lng=-84.0833&to_lat=9.9433&to_lng=-84.0733"},
		{"geo eta", "/api/v1/geo/eta?from_lat=9.9333&from_lng=-84.0833&to_lat=9.9433&to_lng=-84.0733"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// The rider registers through this server (its own mock user repo).
			navOutage.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
				"email":    "route.outage@test.com",
				"phone":    "+1717171718",
				"password": "SecurePass1",
			})
			navOutage.LoginAsRider("route.outage@test.com", "SecurePass1")

			resp := navOutage.Get(tc.path)

			// The whole point: a genuine outage is never the client's fault.
			if resp.StatusCode >= 400 && resp.StatusCode < 500 {
				t.Fatalf("route outage answered %d; a 4xx makes the apps draw a straight-line route as if it were real", resp.StatusCode)
			}
			resp.AssertStatus(t, http.StatusInternalServerError)

			var envelope struct {
				Error struct {
					Code    string `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if err := json.Unmarshal(resp.Body, &envelope); err != nil {
				t.Fatalf("decoding error envelope: %v (body=%s)", err, resp.Body)
			}
			if envelope.Error.Code != "INTERNAL" {
				t.Errorf("code = %q, want INTERNAL", envelope.Error.Code)
			}
			if envelope.Error.Message != "failed to calculate route" {
				t.Errorf("message = %q, want 'failed to calculate route'", envelope.Error.Message)
			}
			if strings.Contains(string(resp.Body), "pq:") || strings.Contains(string(resp.Body), "road_network_edges_pgr") {
				t.Errorf("body leaks the driver error: %s", resp.Body)
			}
		})
	}
}
