package tests

import (
	"net/http"
	"testing"
)

func TestNavigationRouteReturnsEdgeSequence(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.nav@test.com",
		"phone":    "+2323232323",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.nav@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/navigation/route?from=40.7128,-74.0060&to=40.7580,-73.9855",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
	resp.AssertJSONHas(t, "total_distance_m")
	resp.AssertJSONHas(t, "total_duration_s")
}

func TestGeoETA(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.eta@test.com",
		"phone":    "+2424242424",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.eta@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/geo/eta?from=40.7128,-74.0060&to=40.7580,-73.9855",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
}

func TestGeoIsochrone(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.iso@test.com",
		"phone":    "+2525252525",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.iso@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	resp := ts.DoRequest("GET", "/api/v1/geo/isochrone?lat=40.7128&lng=-74.0060&duration_s=600",
		loginResult.AccessToken, nil)
	resp.AssertStatus(t, http.StatusOK)
}
