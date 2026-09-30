package tests

// TEMPORARY pre-fix probe: the rider-visible HTTP status for an uncovered pin.
// Deleted once the permanent tests are in place.

import (
	"net/http"
	"testing"

	"ride-hailing-api/internal/routing"
	"ride-hailing-api/tests/testutil"
)

func TestPreFixProbeUncoveredPinHTTPStatus(t *testing.T) {
	// routing.ErrNoRoute is EXACTLY what the pre-fix native graph gate returned
	// for a pin beyond the snap radius (see the repository probe).
	srv := testutil.NewTestServerWithNav(t, testutil.NewFailingNavigationRepo(routing.ErrNoRoute))
	defer srv.Close()

	srv.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
		"email":    "prefix.probe@test.com",
		"phone":    "+15550009999",
		"password": "SecurePass1",
	})
	srv.LoginAsRider("prefix.probe@test.com", "SecurePass1")

	resp := srv.Get("/api/v1/navigation/route?from_lat=9.9333&from_lng=-84.0833&to_lat=9.9433&to_lng=-84.0733")
	t.Logf("PRE-FIX HTTP status for an uncovered pin: %d body=%s", resp.StatusCode, resp.Body)
	if resp.StatusCode != http.StatusInternalServerError {
		t.Logf("PRE-FIX status is %d (not 500)", resp.StatusCode)
	}
}
