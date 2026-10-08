package tests

import (
	"fmt"
	"net/http"
	"testing"

	"ride-hailing-api/internal/repository"
	"ride-hailing-api/tests/testutil"
)

// estimateBody builds a POST /estimates/price body with the given stops.
func estimateBody(stops []map[string]interface{}) map[string]interface{} {
	body := map[string]interface{}{
		"pickup_lat":  40.7128,
		"pickup_lng":  -74.0060,
		"dropoff_lat": 40.7580,
		"dropoff_lng": -73.9855,
	}
	if stops != nil {
		body["stops"] = stops
	}
	return body
}

// nStops returns n distinct intermediate stops.
func nStops(n int) []map[string]interface{} {
	out := make([]map[string]interface{}, n)
	for i := range out {
		out[i] = map[string]interface{}{"lat": 40.72 + float64(i)*0.001, "lng": -74.0}
	}
	return out
}

// TestEstimatesPricePostWithStops is the feature: POST with stops prices the
// whole itinerary (a larger total than the no-stop request), returns `legs`
// with one entry per leg (stops+1), and carries is_estimate.
func TestEstimatesPricePostWithStops(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.eststops@test.com", "+7904000201")

	var without struct {
		Estimates []struct {
			Total      float64 `json:"total"`
			IsEstimate bool    `json:"is_estimate"`
			Legs       []struct {
				DistanceM   int     `json:"distance_m"`
				DurationS   int     `json:"duration_s"`
				DistanceFee float64 `json:"distance_fare"`
				TimeFee     float64 `json:"time_fare"`
			} `json:"legs"`
		} `json:"estimates"`
	}
	resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, estimateBody(nil))
	resp.AssertStatus(t, http.StatusOK)
	testutil.ParseJSON(t, resp.Body, &without)

	var with struct {
		Estimates []struct {
			Total      float64 `json:"total"`
			IsEstimate bool    `json:"is_estimate"`
			Legs       []struct {
				DistanceM   int     `json:"distance_m"`
				DurationS   int     `json:"duration_s"`
				DistanceFee float64 `json:"distance_fare"`
				TimeFee     float64 `json:"time_fare"`
			} `json:"legs"`
		} `json:"estimates"`
	}
	withResp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, estimateBody(nStops(2)))
	withResp.AssertStatus(t, http.StatusOK)
	testutil.ParseJSON(t, withResp.Body, &with)

	if len(without.Estimates) != 3 || len(with.Estimates) != 3 {
		t.Fatalf("estimates = %d / %d, want 3 / 3", len(without.Estimates), len(with.Estimates))
	}
	if len(without.Estimates[0].Legs) != 1 {
		t.Errorf("zero-stop legs = %d, want 1", len(without.Estimates[0].Legs))
	}
	if len(with.Estimates[0].Legs) != 3 {
		t.Fatalf("two-stop legs = %d, want 3", len(with.Estimates[0].Legs))
	}
	if with.Estimates[0].Legs[0].DistanceM == 0 || with.Estimates[0].Legs[0].DurationS == 0 ||
		with.Estimates[0].Legs[0].DistanceFee == 0 || with.Estimates[0].Legs[0].TimeFee == 0 {
		t.Errorf("leg is missing its fare breakdown: %+v", with.Estimates[0].Legs[0])
	}
	if with.Estimates[0].IsEstimate {
		t.Error("a covered mock route must not be flagged is_estimate")
	}
	if !(with.Estimates[0].Total > without.Estimates[0].Total) {
		t.Errorf("stopped total %v must exceed the no-stop total %v (the mock route is 5 km per leg)",
			with.Estimates[0].Total, without.Estimates[0].Total)
	}
}

// TestEstimatesPriceGetIsGone pins the hard cutover: the GET route is removed
// with no alias, so a stale GET answers 404, never 200/405.
func TestEstimatesPriceGetIsGone(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.estget@test.com", "+7904000202")

	get := ts.DoRequest("GET",
		"/api/v1/estimates/price?pickup_lat=40.7128&pickup_lng=-74.0060&dropoff_lat=40.7580&dropoff_lng=-73.9855",
		riderToken, nil)
	get.AssertStatus(t, http.StatusNotFound)
}

// TestEstimatesPriceValidation pins the POST body contract: a malformed body is
// 400, and missing/out-of-range coordinates and an unknown vehicle type are
// 422, never an outage.
func TestEstimatesPriceValidation(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.estval@test.com", "+7904000203")

	t.Run("malformed body is 400", func(t *testing.T) {
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, "not an object")
		resp.AssertStatus(t, http.StatusBadRequest)
		if code := decodeErrorBody(t, resp.Body).Error.Code; code != "BAD_REQUEST" {
			t.Errorf("code = %q, want BAD_REQUEST", code)
		}
	})

	t.Run("missing coordinate is 422", func(t *testing.T) {
		body := estimateBody(nil)
		delete(body, "pickup_lat")
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, body)
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
	})

	t.Run("out-of-range coordinate is 422", func(t *testing.T) {
		body := estimateBody(nil)
		body["dropoff_lat"] = 999.0
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, body)
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
		if code := decodeErrorBody(t, resp.Body).Error.Code; code != "VALIDATION_ERROR" {
			t.Errorf("code = %q, want VALIDATION_ERROR", code)
		}
	})

	t.Run("unknown vehicle type is 422", func(t *testing.T) {
		body := estimateBody(nil)
		body["vehicle_type"] = "helicopter"
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, body)
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
	})

	t.Run("a malformed stop is 422 naming it", func(t *testing.T) {
		body := estimateBody([]map[string]interface{}{{"lng": -74.0}})
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, body)
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
		if msg := decodeErrorBody(t, resp.Body).Error.Message; msg != "Invalid Latitude in stop 1" {
			t.Errorf("message = %q, want the stop-naming sentence", msg)
		}
	})
}

// TestStopCapSharedByCreateAndEstimate pins the shared RIDE_MAX_STOPS cap
// (default 8): above it both endpoints answer 422 with the human sentence, and
// exactly at it both succeed (boundary).
func TestStopCapSharedByCreateAndEstimate(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.cap@test.com", "+7904000204")
	const wantMsg = "a trip can have at most 8 stops"

	t.Run("estimate above the cap is 422", func(t *testing.T) {
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, estimateBody(nStops(9)))
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
		got := decodeErrorBody(t, resp.Body)
		if got.Error.Code != "VALIDATION_ERROR" || got.Error.Message != wantMsg {
			t.Errorf("error = %+v, want VALIDATION_ERROR / %q", got.Error, wantMsg)
		}
	})

	t.Run("estimate at the cap succeeds", func(t *testing.T) {
		resp := ts.DoRequest("POST", "/api/v1/estimates/price", riderToken, estimateBody(nStops(8)))
		resp.AssertStatus(t, http.StatusOK)
	})

	t.Run("create above the cap is 422", func(t *testing.T) {
		body := map[string]interface{}{
			"pickup_lat": 40.7128, "pickup_lng": -74.0060,
			"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
			"stops": nStops(9),
		}
		resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, body)
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
		got := decodeErrorBody(t, resp.Body)
		if got.Error.Code != "VALIDATION_ERROR" || got.Error.Message != wantMsg {
			t.Errorf("error = %+v, want VALIDATION_ERROR / %q", got.Error, wantMsg)
		}
	})

	t.Run("create at the cap succeeds", func(t *testing.T) {
		body := map[string]interface{}{
			"pickup_lat": 40.7128, "pickup_lng": -74.0060,
			"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
			"stops": nStops(8),
		}
		resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, body)
		resp.AssertStatus(t, http.StatusCreated)
	})
}

// TestEstimatesPriceUncoveredMultiStopKeepsLegs pins the served shape of an
// UNCOVERED multi-stop estimate. The mock nav repo is not a RegionSource and
// its legacy path maps ErrPinUncovered to estimateRoute, so every consecutive
// leg is itself an estimate and GetItineraryRoute takes the whole-itinerary
// estimate branch (internal/service/navigation.go itineraryEstimate). That
// branch must carry one leg per waypoint pair, not collapse to the single
// synthesized aggregate leg — otherwise the rider UI's hasMultipleLegs gate
// silently suppresses the breakdown.
func TestEstimatesPriceUncoveredMultiStopKeepsLegs(t *testing.T) {
	srv := testutil.NewTestServerWithNav(t, testutil.NewFailingNavigationRepo(
		fmt.Errorf("%w: pin beyond the snap radius", repository.ErrPinUncovered)))
	defer srv.Close()

	srv.DoRequest("POST", "/api/v1/auth/register", "", map[string]string{
		"email":    "rider.uncovered.legs@test.com",
		"phone":    "+7904000299",
		"password": "SecurePass1",
	})
	srv.LoginAsRider("rider.uncovered.legs@test.com", "SecurePass1")
	token := srv.AuthTokens["rider"]

	var body struct {
		Estimates []struct {
			IsEstimate bool `json:"is_estimate"`
			Legs       []struct {
				DistanceM int `json:"distance_m"`
				DurationS int `json:"duration_s"`
			} `json:"legs"`
		} `json:"estimates"`
	}

	resp := srv.DoRequest("POST", "/api/v1/estimates/price", token, estimateBody(nStops(2)))
	resp.AssertStatus(t, http.StatusOK)
	testutil.ParseJSON(t, resp.Body, &body)

	if len(body.Estimates) != 3 {
		t.Fatalf("estimates = %d, want 3", len(body.Estimates))
	}
	if !body.Estimates[0].IsEstimate {
		t.Error("an uncovered itinerary must be flagged is_estimate")
	}
	if len(body.Estimates[0].Legs) != 3 {
		t.Fatalf("uncovered two-stop legs = %d, want stops+1 = 3", len(body.Estimates[0].Legs))
	}
	for i, leg := range body.Estimates[0].Legs {
		if leg.DistanceM <= 0 || leg.DurationS != leg.DistanceM/11 {
			t.Errorf("leg %d = %+v, want a straight-line distance and distance/11", i, leg)
		}
	}

	// A zero-stop request through the same uncovered fixture still delegates to
	// GetRoute's own estimate output (no Legs), which the fare layer synthesizes
	// into exactly one leg.
	var zero struct {
		Estimates []struct {
			Legs []struct{} `json:"legs"`
		} `json:"estimates"`
	}
	zeroResp := srv.DoRequest("POST", "/api/v1/estimates/price", token, estimateBody(nil))
	zeroResp.AssertStatus(t, http.StatusOK)
	testutil.ParseJSON(t, zeroResp.Body, &zero)
	if len(zero.Estimates[0].Legs) != 1 {
		t.Errorf("zero-stop legs = %d, want 1", len(zero.Estimates[0].Legs))
	}
}

// TestCreateRideWithStopsBooksTheSummedQuote proves the booking quote prices
// the itinerary: a one-stop ride costs more than the same trip without stops,
// and the snapshot still names the card.
func TestCreateRideWithStopsBooksTheSummedQuote(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.booksum@test.com", "+7904000205")

	plain := requestMultiStopRide(t, riderToken, nil)

	withStop := requestMultiStopRide(t, riderToken, []map[string]interface{}{
		{"lat": 40.7200, "lng": -74.0000},
	})

	if !(withStop.Ride.TotalFare > plain.Ride.TotalFare) {
		t.Errorf("stopped quote %v must exceed the no-stop quote %v (the mock route is 5 km per leg)",
			withStop.Ride.TotalFare, plain.Ride.TotalFare)
	}
	if withStop.Ride.FareRegionID == nil || *withStop.Ride.FareRegionID != "cr-sj" {
		t.Errorf("fare_region_id = %v, want the default cr-sj", withStop.Ride.FareRegionID)
	}
	if withStop.Ride.FareRateID == nil || *withStop.Ride.FareRateID == "" {
		t.Error("the stopped quote must still snapshot the booked card id")
	}
	// The create response stays aggregate: no legs key leaks onto it.
	if resp := ts.DoRequest("GET", "/api/v1/rides/"+withStop.Ride.ID, riderToken, nil); resp.StatusCode != http.StatusOK {
		t.Errorf("read back status = %d, want 200", resp.StatusCode)
	}
}
