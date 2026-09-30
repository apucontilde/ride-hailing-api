package tests

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strings"
	"testing"

	"ride-hailing-api/internal/repository"
	"ride-hailing-api/internal/routing"
	"ride-hailing-api/tests/testutil"
)

// An uncovered pin is a DATA gap and must be answered like one: HTTP 200, a
// straight line, and is_estimate=true. It is the rider-visible half of the fix
// for the regression where the snap-radius gate reported routing.ErrNoRoute and
// the handler turned that into 500 INTERNAL "failed to calculate route" — which
// the rider app renders as a straight line with no is_estimate flag to say it
// is not a road route (rider_app .../home_screen.dart:157).
//
// The mock repository has no RegionSource, so this drives the LEGACY path, the
// one that had no estimate branch at all; the region path's mapping is pinned in
// internal/service/pin_uncovered_test.go. Both share the same degradation.
func TestUncoveredPinAnswers200EstimateNot500(t *testing.T) {
	srv := testutil.NewTestServerWithNav(t, testutil.NewFailingNavigationRepo(
		fmt.Errorf("%w: pickup is 50113 m from the nearest road vertex, beyond the 50000 m snap radius",
			repository.ErrPinUncovered)))
	defer srv.Close()

	srv.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
		"email":    "uncovered.pin@test.com",
		"phone":    "+15550001234",
		"password": "SecurePass1",
	})
	srv.LoginAsRider("uncovered.pin@test.com", "SecurePass1")

	const (
		fromLat, fromLng = 9.9333, -84.0833
		toLat, toLng     = 9.9433, -84.0733
	)
	query := fmt.Sprintf("?from_lat=%f&from_lng=%f&to_lat=%f&to_lng=%f", fromLat, fromLng, toLat, toLng)

	t.Run("navigation route", func(t *testing.T) {
		resp := srv.Get("/api/v1/navigation/route" + query)
		resp.AssertStatus(t, http.StatusOK)

		var body struct {
			Polyline []struct {
				Lat float64 `json:"lat"`
				Lng float64 `json:"lng"`
			} `json:"polyline"`
			TotalDistanceM int  `json:"total_distance_m"`
			TotalDurationS int  `json:"total_duration_s"`
			IsEstimate     bool `json:"is_estimate"`
		}
		if err := json.Unmarshal(resp.Body, &body); err != nil {
			t.Fatalf("decoding response: %v (body=%s)", err, resp.Body)
		}

		if !body.IsEstimate {
			t.Error("is_estimate must be true: without it the client cannot tell this line is not a road route")
		}
		want := int(math.Round(routing.HaversineMeters(fromLat, fromLng, toLat, toLng)))
		if body.TotalDistanceM != want {
			t.Errorf("total_distance_m = %d, want the straight line %d m", body.TotalDistanceM, want)
		}
		if body.TotalDurationS != want/11 {
			t.Errorf("total_duration_s = %d, want %d (distance / 11)", body.TotalDurationS, want/11)
		}
		if len(body.Polyline) != 2 {
			t.Fatalf("polyline has %d points, want exactly the 2 pins: %s", len(body.Polyline), resp.Body)
		}
		if body.Polyline[0].Lat != fromLat || body.Polyline[0].Lng != fromLng ||
			body.Polyline[1].Lat != toLat || body.Polyline[1].Lng != toLng {
			t.Errorf("polyline must be the two pins, got %s", resp.Body)
		}
	})

	t.Run("geo eta", func(t *testing.T) {
		resp := srv.Get("/api/v1/geo/eta" + query)
		resp.AssertStatus(t, http.StatusOK)
		if !strings.Contains(string(resp.Body), `"is_estimate":true`) {
			t.Errorf("body = %s, want is_estimate=true", resp.Body)
		}
	})
}

// The other side of the same contract: a pair of pins the network cannot connect
// is a real routing failure and stays 500 INTERNAL. The fix must not have turned
// it into a straight line that looks like a served route.
func TestNoRouteBetweenCoveredPinsStays500(t *testing.T) {
	srv := testutil.NewTestServerWithNav(t, testutil.NewFailingNavigationRepo(routing.ErrNoRoute))
	defer srv.Close()

	srv.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
		"email":    "no.route@test.com",
		"phone":    "+15550005678",
		"password": "SecurePass1",
	})
	srv.LoginAsRider("no.route@test.com", "SecurePass1")

	resp := srv.Get("/api/v1/navigation/route?from_lat=9.9333&from_lng=-84.0833&to_lat=9.9433&to_lng=-84.0733")
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
	// The cause belongs in the log line, never in the public message.
	if strings.Contains(string(resp.Body), routing.ErrNoRoute.Error()) {
		t.Errorf("body leaks the internal cause %q: %s", routing.ErrNoRoute, resp.Body)
	}
}
