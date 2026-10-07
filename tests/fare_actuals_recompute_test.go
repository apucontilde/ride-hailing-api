package tests

import (
	"net/http"
	"testing"
	"time"

	"ride-hailing-api/tests/testutil"
)

// These end-to-end tests pin the completion fare recompute
// (api_plans/01_[fare]_actuals_recompute_on_completion.md) through the real
// handler -> service -> repository wiring on the db-less harness: the booked
// quote is captured, the final charge is recomputed from the actuals, and every
// read path (ride JSON, receipt, completion WS) resolves to the final. The
// precise arithmetic is pinned by internal/service/fare_recompute_test.go; here
// the load-bearing facts are persistence, read-path resolution, and idempotency.

// SeedTrace inserts a two-fix trace spanning the given latitude delta over the
// given seconds, so DrivenDistanceMeters accepts it (speed below the teleport
// gate) and yields a controllable actual distance.
func seedTrace(t *testing.T, rideID string, latFrom, latTo float64, span time.Duration) {
	t.Helper()
	base := time.Now().Add(-span - time.Minute)
	points := []struct {
		lat float64
		at  time.Duration
	}{
		{latFrom, 0},
		{latTo, span},
	}
	for _, p := range points {
		if err := ts.RideRepo.InsertRideTrackPoint(rideID, p.lat, -74.0, base.Add(p.at)); err != nil {
			t.Fatalf("seed track point: %v", err)
		}
	}
}

// TestRideFinalFareRecomputedFromActualsUp is the up-direction proof: actuals
// above the booked route recompute a higher final charge, the quote is captured
// for audit, and the WS + receipt + ride JSON all carry the final.
func TestRideFinalFareRecomputedFromActualsUp(t *testing.T) {
	riderConn, riderToken, driverToken, rideID, _ := setupAcceptedRide(t, 960)

	advanceTo(t, driverToken, rideID, "driver_arrived", "in_progress")
	testutil.ReadWSMessage(t, riderConn)
	testutil.ReadWSMessage(t, riderConn)

	quote, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read quote: %v", err)
	}
	if quote.FareRateID == nil {
		t.Fatal("ride has no booked card id; the test cannot exercise the recompute")
	}
	quotedTotal := quote.TotalFare

	// ~11.1 km actual, well above the ~5 km booked mock route.
	seedTrace(t, rideID, 40.0, 40.10, 5*time.Minute)

	advanceTo(t, driverToken, rideID, "completed")
	completed := readCompletedUpdate(t, riderConn, rideID)

	finalFare, ok := completed["fare"].(map[string]interface{})
	if !ok {
		t.Fatalf("completed event missing fare: %v", completed)
	}
	finalTotal, _ := finalFare["total"].(float64)
	if finalTotal <= quotedTotal {
		t.Fatalf("final total = %v, want above the quoted %v for a longer actual", finalTotal, quotedTotal)
	}

	// Defect 4: the completion fare must actually carry the identity/applied
	// fields the driver app reads (`fare.currency`, `fare.grade_uplift_pct`).
	if finalFare["currency"] != "USD" {
		t.Errorf("completion fare.currency = %v, want USD", finalFare["currency"])
	}
	if finalFare["region_id"] != "cr-sj" {
		t.Errorf("completion fare.region_id = %v, want cr-sj", finalFare["region_id"])
	}
	if _, ok := finalFare["grade_uplift_pct"]; !ok {
		t.Errorf("completion fare is missing grade_uplift_pct: %v", finalFare)
	}

	// Persistence: the plain columns hold the final, the quoted_* audit columns
	// hold the quote.
	stored, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read stored ride: %v", err)
	}
	if stored.TotalFare != finalTotal {
		t.Errorf("stored total_fare = %v, want the final %v", stored.TotalFare, finalTotal)
	}
	if stored.QuotedTotalFare == nil || *stored.QuotedTotalFare != quotedTotal {
		t.Errorf("quoted_total_fare = %v, want the booked quote %v", stored.QuotedTotalFare, quotedTotal)
	}

	// Read path: the ride JSON and the receipt both resolve to the final with no
	// quote line.
	getResp := ts.DoRequest("GET", "/api/v1/rides/"+rideID, riderToken, nil)
	getResp.AssertStatus(t, http.StatusOK)
	getResp.AssertJSONHas(t, "ride.total_fare", finalTotal)

	receipt := ts.DoRequest("GET", "/api/v1/rides/"+rideID+"/receipt", riderToken, nil)
	receipt.AssertStatus(t, http.StatusOK)
	receipt.AssertJSONHas(t, "receipt.total", finalTotal)

	// Idempotency: a retried completion is rejected by the status machine and
	// leaves the finalized fare untouched.
	retry := ts.DoRequest("PUT", "/api/v1/driver/rides/"+rideID+"/status", driverToken,
		map[string]string{"status": "completed"})
	retry.AssertStatus(t, http.StatusBadRequest)
	afterRetry, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read after retry: %v", err)
	}
	if afterRetry.TotalFare != finalTotal || afterRetry.QuotedTotalFare == nil || *afterRetry.QuotedTotalFare != quotedTotal {
		t.Errorf("retry moved the fare: total %v quoted %v, want %v / %v",
			afterRetry.TotalFare, afterRetry.QuotedTotalFare, finalTotal, quotedTotal)
	}
}

// TestRideFinalFareRecomputedFromActualsDown is the down-direction proof of the
// uncapped policy: a shorter actual charges less than the quote.
func TestRideFinalFareRecomputedFromActualsDown(t *testing.T) {
	riderConn, _, driverToken, rideID, _ := setupAcceptedRide(t, 961)

	advanceTo(t, driverToken, rideID, "driver_arrived", "in_progress")
	testutil.ReadWSMessage(t, riderConn)
	testutil.ReadWSMessage(t, riderConn)

	quote, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read quote: %v", err)
	}
	quotedTotal := quote.TotalFare

	// ~1.1 km actual, well below the ~5 km booked mock route.
	seedTrace(t, rideID, 40.0, 40.01, time.Minute)

	advanceTo(t, driverToken, rideID, "completed")
	completed := readCompletedUpdate(t, riderConn, rideID)

	finalFare, _ := completed["fare"].(map[string]interface{})
	finalTotal, _ := finalFare["total"].(float64)
	if finalTotal >= quotedTotal {
		t.Fatalf("final total = %v, want below the quoted %v for a shorter actual", finalTotal, quotedTotal)
	}

	stored, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read stored ride: %v", err)
	}
	if stored.TotalFare != finalTotal {
		t.Errorf("stored total_fare = %v, want the final %v", stored.TotalFare, finalTotal)
	}
	if stored.QuotedTotalFare == nil || *stored.QuotedTotalFare != quotedTotal {
		t.Errorf("quoted_total_fare = %v, want the booked quote %v", stored.QuotedTotalFare, quotedTotal)
	}
}

// TestRideFinalFareFallsBackWithoutTrace pins the no-fabrication contract: with
// no usable trace the booked quote is charged unchanged, and it is still
// captured exactly once as the quote.
func TestRideFinalFareFallsBackWithoutTrace(t *testing.T) {
	riderConn, riderToken, driverToken, rideID, _ := setupAcceptedRide(t, 962)

	advanceTo(t, driverToken, rideID, "driver_arrived", "in_progress")
	testutil.ReadWSMessage(t, riderConn)
	testutil.ReadWSMessage(t, riderConn)

	quote, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read quote: %v", err)
	}
	quotedTotal := quote.TotalFare

	// No trace seeded.
	advanceTo(t, driverToken, rideID, "completed")
	completed := readCompletedUpdate(t, riderConn, rideID)

	// actual_distance_m is NULL on the wire (never a fabricated 0).
	if v, ok := completed["actual_distance_m"]; ok && v != nil {
		t.Errorf("actual_distance_m = %v, want null without a trace", v)
	}

	finalFare, _ := completed["fare"].(map[string]interface{})
	finalTotal, _ := finalFare["total"].(float64)
	if finalTotal != quotedTotal {
		t.Fatalf("final total = %v, want the unchanged quote %v", finalTotal, quotedTotal)
	}

	stored, err := ts.RideRepo.FindByID(rideID)
	if err != nil {
		t.Fatalf("read stored ride: %v", err)
	}
	if stored.TotalFare != quotedTotal {
		t.Errorf("stored total_fare = %v, want the quote %v", stored.TotalFare, quotedTotal)
	}
	if stored.QuotedTotalFare == nil || *stored.QuotedTotalFare != quotedTotal {
		t.Errorf("quoted_total_fare = %v, want the quote captured %v", stored.QuotedTotalFare, quotedTotal)
	}

	// The read paths agree.
	getResp := ts.DoRequest("GET", "/api/v1/rides/"+rideID, riderToken, nil)
	getResp.AssertStatus(t, http.StatusOK)
	getResp.AssertJSONHas(t, "ride.total_fare", quotedTotal)
	receipt := ts.DoRequest("GET", "/api/v1/rides/"+rideID+"/receipt", riderToken, nil)
	receipt.AssertStatus(t, http.StatusOK)
	receipt.AssertJSONHas(t, "receipt.total", quotedTotal)
}
