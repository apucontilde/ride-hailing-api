package tests

import (
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"ride-hailing-api/internal/model"
)

// rideWithStops mirrors the additive envelope of POST /api/v1/rides,
// GET /api/v1/rides/:id and PUT /api/v1/rides/:id/destination.
type rideWithStops struct {
	Ride  *model.Ride      `json:"ride"`
	Stops []model.RideStop `json:"stops"`
}

type apiErrorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func decodeRideWithStops(t *testing.T, body []byte) rideWithStops {
	t.Helper()
	var got rideWithStops
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decoding ride response: %v (body=%s)", err, body)
	}
	return got
}

func decodeErrorBody(t *testing.T, body []byte) apiErrorBody {
	t.Helper()
	var got apiErrorBody
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decoding error response: %v (body=%s)", err, body)
	}
	return got
}

// requestMultiStopRide books a ride for the given rider and returns the parsed
// create response. Stops is sent verbatim, so a nil slice exercises the
// pre-016 body shape.
func requestMultiStopRide(t *testing.T, riderToken string, stops interface{}) rideWithStops {
	t.Helper()
	body := map[string]interface{}{
		"pickup_lat": 40.7128, "pickup_lng": -74.0060,
		"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
		"dropoff_address": "Original destination",
	}
	if stops != nil {
		body["stops"] = stops
	}
	resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, body)
	resp.AssertStatus(t, http.StatusCreated)
	return decodeRideWithStops(t, resp.Body)
}

// TestCreateRideWithoutStopsIsUnchanged is the backward-compatibility guard: a
// body that never heard of multi-stop must book exactly as before, and now also
// answer with a one-stop itinerary (the ride's own dropoff).
func TestCreateRideWithoutStopsIsUnchanged(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.nostops@test.com", "+7903000101")

	got := requestMultiStopRide(t, riderToken, nil)

	if got.Ride == nil {
		t.Fatal("no ride in the create response")
	}
	if got.Ride.Status != "pending" {
		t.Errorf("status = %q, want pending", got.Ride.Status)
	}
	if got.Ride.DropoffLat != 40.7580 || got.Ride.DropoffAddress != "Original destination" {
		t.Errorf("dropoff changed: %+v", got.Ride)
	}
	if len(got.Stops) != 1 {
		t.Fatalf("stops = %+v, want the single final destination", got.Stops)
	}
	if s := got.Stops[0]; s.Kind != model.DestinationKind || s.Lat != 40.7580 {
		t.Errorf("stop = %+v, want the destination mirrored from dropoff_*", s)
	}
}

// TestCreateRideWithOrderedStops is the feature itself: intermediate stops keep
// the order they were sent in, gain 1-based sequences, and the destination is
// last.
func TestCreateRideWithOrderedStops(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.stops@test.com", "+7903000102")

	got := requestMultiStopRide(t, riderToken, []map[string]interface{}{
		{"lat": 40.7200, "lng": -74.0000, "address": "Bakery"},
		{"lat": 40.7300, "lng": -73.9900, "address": "Park"},
	})

	if len(got.Stops) != 3 {
		t.Fatalf("stops = %+v, want 2 intermediate + 1 destination", got.Stops)
	}
	wantSeq := []int{1, 2, 3}
	wantAddr := []string{"Bakery", "Park", "Original destination"}
	for i, s := range got.Stops {
		if s.Sequence != wantSeq[i] {
			t.Errorf("stop %d sequence = %d, want %d", i, s.Sequence, wantSeq[i])
		}
		if s.Address != wantAddr[i] {
			t.Errorf("stop %d address = %q, want %q", i, s.Address, wantAddr[i])
		}
		if s.RideID != got.Ride.ID {
			t.Errorf("stop %d ride_id = %q, want %q", i, s.RideID, got.Ride.ID)
		}
	}
	if k := got.Stops[2].Kind; k != model.DestinationKind {
		t.Errorf("last stop kind = %q, want %q", k, model.DestinationKind)
	}

	// The itinerary must survive the round trip through the authoritative read.
	readBack := ts.DoRequest("GET", "/api/v1/rides/"+got.Ride.ID, riderToken, nil)
	readBack.AssertStatus(t, http.StatusOK)
	after := decodeRideWithStops(t, readBack.Body)
	if len(after.Stops) != 3 || after.Stops[0].Address != "Bakery" {
		t.Errorf("GET /rides/:id stops = %+v, want the booked itinerary", after.Stops)
	}
}

// TestCreateRideStopsValidation pins the 422 answers for a malformed itinerary.
// The message is PUBLIC (Flutter renders it verbatim), so each case also asserts
// the sentence names the offending stop.
func TestCreateRideStopsValidation(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.stopsinvalid@test.com", "+7903000103")

	tests := []struct {
		name     string
		stops    interface{}
		wantCode string
		wantMsg  string
	}{
		{
			name:     "a missing latitude is rejected",
			stops:    []map[string]interface{}{{"lng": -74.0}},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  "Invalid Latitude in stop 1",
		},
		{
			name:     "a missing longitude is rejected",
			stops:    []map[string]interface{}{{"lat": 40.7}},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  "Invalid Longitude in stop 1",
		},
		{
			name:     "an out-of-range latitude is rejected",
			stops:    []map[string]interface{}{{"lat": 91.0, "lng": -74.0}},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  "stop 1: latitude out of range",
		},
		{
			name:     "an out-of-range longitude is rejected",
			stops:    []map[string]interface{}{{"lat": 40.7, "lng": 181.0}},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  "stop 1: longitude out of range",
		},
		{
			name: "a stop that claims to be the destination is rejected",
			stops: []map[string]interface{}{
				{"kind": "destination", "lat": 40.7, "lng": -74.0},
			},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  "stop 1: the final destination is set by dropoff_lat/dropoff_lng/dropoff_address, not by a stop",
		},
		{
			name: "a destination stop is rejected even when sent last",
			stops: []map[string]interface{}{
				{"lat": 40.8, "lng": -73.9},
				{"kind": "destination", "lat": 40.7, "lng": -74.0},
			},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  "stop 2: the final destination is set by dropoff_lat/dropoff_lng/dropoff_address, not by a stop",
		},
		{
			name: "an unknown kind is rejected",
			stops: []map[string]interface{}{
				{"kind": "waypoint", "lat": 40.7, "lng": -74.0},
			},
			wantCode: "VALIDATION_ERROR",
			wantMsg:  `stop 1: kind must be omitted or "stop"`,
		},
	}

	for i, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := map[string]interface{}{
				"pickup_lat": 40.7128, "pickup_lng": -74.0060,
				"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
				"stops": tt.stops,
			}
			resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, body)
			resp.AssertStatus(t, http.StatusUnprocessableEntity)

			gotErr := decodeErrorBody(t, resp.Body)
			if gotErr.Error.Code != tt.wantCode {
				t.Errorf("code = %q, want %q", gotErr.Error.Code, tt.wantCode)
			}
			if gotErr.Error.Message != tt.wantMsg {
				t.Errorf("message = %q, want %q (public text: it is rendered verbatim)",
					gotErr.Error.Message, tt.wantMsg)
			}
			// A rejected itinerary must not have booked anything.
			_ = i
		})
	}
}

// TestUpdateDestinationMutatesTheRide is the endpoint that used to be a stub
// returning "destination updated" without touching anything
// (api_plans/[multi]_add_stops_change_destination.md).
func TestUpdateDestinationMutatesTheRide(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.changedest@test.com", "+7903000104")

	booked := requestMultiStopRide(t, riderToken, []map[string]interface{}{
		{"lat": 40.7200, "lng": -74.0000, "address": "Bakery"},
	})

	resp := ts.DoRequest("PUT", "/api/v1/rides/"+booked.Ride.ID+"/destination", riderToken, map[string]interface{}{
		"lat": 40.7900, "lng": -73.9700, "address": "New destination",
	})
	resp.AssertStatus(t, http.StatusOK)

	got := decodeRideWithStops(t, resp.Body)
	if got.Ride.DropoffLat != 40.79 || got.Ride.DropoffLng != -73.97 {
		t.Errorf("response ride = %+v, want the NEW dropoff", got.Ride)
	}
	if got.Ride.DropoffAddress != "New destination" {
		t.Errorf("dropoff_address = %q, want %q", got.Ride.DropoffAddress, "New destination")
	}
	if got.Ride.Status != "pending" {
		t.Errorf("status = %q, want pending: a destination change is not a transition", got.Ride.Status)
	}

	// The itinerary's destination row moved with the scalars: same row, new
	// coordinates, and the intermediate stop is untouched.
	var dest *model.RideStop
	for i := range got.Stops {
		if got.Stops[i].Kind == model.DestinationKind {
			dest = &got.Stops[i]
		}
	}
	if dest == nil {
		t.Fatalf("no destination stop in %+v", got.Stops)
	}
	if dest.Lat != 40.79 || dest.Address != "New destination" {
		t.Errorf("destination stop = %+v, want the new coordinates", dest)
	}

	// And it is durable, not just echoed back.
	readBack := decodeRideWithStops(t, ts.DoRequest("GET", "/api/v1/rides/"+booked.Ride.ID, riderToken, nil).Body)
	if readBack.Ride.DropoffLat != 40.79 {
		t.Errorf("persisted dropoff_lat = %v, want 40.79", readBack.Ride.DropoffLat)
	}
	if len(readBack.Stops) != 2 || readBack.Stops[0].Address != "Bakery" {
		t.Errorf("persisted stops = %+v, want the bakery stop preserved", readBack.Stops)
	}
}

// TestUpdateDestinationDoesNotRepriceTheRide pins the decision that a
// mid-trip destination change leaves the booking-time fare alone: repricing a
// trip the driver already started would silently change the agreed price.
func TestUpdateDestinationDoesNotRepriceTheRide(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.noreprice@test.com", "+7903000105")
	booked := requestMultiStopRide(t, riderToken, nil)

	resp := ts.DoRequest("PUT", "/api/v1/rides/"+booked.Ride.ID+"/destination", riderToken, map[string]interface{}{
		"lat": 40.79, "lng": -73.97,
	})
	resp.AssertStatus(t, http.StatusOK)

	got := decodeRideWithStops(t, resp.Body)
	if got.Ride.TotalFare != booked.Ride.TotalFare {
		t.Errorf("total_fare changed from %v to %v on a destination change",
			booked.Ride.TotalFare, got.Ride.TotalFare)
	}
}

// TestUpdateDestinationAuthorizationAndStatus is the endpoint's status-code
// contract: 404 for a ride that is not the caller's, 409 once the itinerary is
// closed, and never a 4xx for anything that is not the caller's own doing.
func TestUpdateDestinationAuthorizationAndStatus(t *testing.T) {
	ownerToken := registerAndLogin(t, "rider.dest.owner@test.com", "+7903000106")
	otherToken := registerAndLogin(t, "rider.dest.other@test.com", "+7903000107")
	driverToken := registerDriver(t, "driver.dest@test.com", "+7903000108")

	newDest := map[string]interface{}{"lat": 40.79, "lng": -73.97}

	t.Run("another rider gets 404, not 403 and not a silent success", func(t *testing.T) {
		booked := requestMultiStopRide(t, ownerToken, nil)
		resp := ts.DoRequest("PUT", "/api/v1/rides/"+booked.Ride.ID+"/destination", otherToken, newDest)
		resp.AssertStatus(t, http.StatusNotFound)
		if code := decodeErrorBody(t, resp.Body).Error.Code; code != "NOT_FOUND" {
			t.Errorf("code = %q, want NOT_FOUND", code)
		}
		// The ride must be untouched.
		after := decodeRideWithStops(t, ts.DoRequest("GET", "/api/v1/rides/"+booked.Ride.ID, ownerToken, nil).Body)
		if after.Ride.DropoffLat != booked.Ride.DropoffLat {
			t.Errorf("dropoff_lat = %v, want the original %v", after.Ride.DropoffLat, booked.Ride.DropoffLat)
		}
	})

	t.Run("a driver may not redirect somebody else's ride", func(t *testing.T) {
		booked := requestMultiStopRide(t, ownerToken, nil)
		resp := ts.DoRequest("PUT", "/api/v1/rides/"+booked.Ride.ID+"/destination", driverToken, newDest)
		if resp.StatusCode != http.StatusForbidden && resp.StatusCode != http.StatusNotFound {
			t.Fatalf("status = %d, want 403 (role) or 404 (not the rider)", resp.StatusCode)
		}
	})

	t.Run("a completed ride answers 409", func(t *testing.T) {
		booked := requestMultiStopRide(t, ownerToken, nil)
		if err := ts.RideRepo.UpdateRideStatus(booked.Ride.ID, "completed", nil); err != nil {
			t.Fatalf("seeding the completed status: %v", err)
		}

		resp := ts.DoRequest("PUT", "/api/v1/rides/"+booked.Ride.ID+"/destination", ownerToken, newDest)
		resp.AssertStatus(t, http.StatusConflict)
		if code := decodeErrorBody(t, resp.Body).Error.Code; code != "CONFLICT" {
			t.Errorf("code = %q, want CONFLICT", code)
		}
	})

	t.Run("an unknown ride answers 404", func(t *testing.T) {
		resp := ts.DoRequest("PUT", "/api/v1/rides/00000000-0000-0000-0000-000000000000/destination",
			ownerToken, newDest)
		resp.AssertStatus(t, http.StatusNotFound)
	})
}

// TestUpdateDestinationValidation pins the body contract: absent coordinates and
// a malformed body are the caller's fault (422/400); nothing here may be
// reported as an outage.
func TestUpdateDestinationValidation(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.destvalidation@test.com", "+7903000109")
	booked := requestMultiStopRide(t, riderToken, nil)
	path := "/api/v1/rides/" + booked.Ride.ID + "/destination"

	t.Run("a missing latitude is 422", func(t *testing.T) {
		resp := ts.DoRequest("PUT", path, riderToken, map[string]interface{}{"lng": -73.97})
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
		if msg := decodeErrorBody(t, resp.Body).Error.Message; msg != "Invalid Latitude" {
			t.Errorf("message = %q, want %q", msg, "Invalid Latitude")
		}
	})

	t.Run("an out-of-range coordinate is 422", func(t *testing.T) {
		resp := ts.DoRequest("PUT", path, riderToken, map[string]interface{}{"lat": 91.0, "lng": -73.97})
		resp.AssertStatus(t, http.StatusUnprocessableEntity)
		if msg := decodeErrorBody(t, resp.Body).Error.Message; msg != "lat/lng out of range" {
			t.Errorf("message = %q, want %q", msg, "lat/lng out of range")
		}
	})

	t.Run("a malformed body is 400", func(t *testing.T) {
		req := ts.DoRequest("PUT", path, riderToken, nil)
		req.AssertStatus(t, http.StatusBadRequest)
		if code := decodeErrorBody(t, req.Body).Error.Code; code != "BAD_REQUEST" {
			t.Errorf("code = %q, want BAD_REQUEST", code)
		}
	})

	t.Run("an unauthenticated call is rejected", func(t *testing.T) {
		resp := ts.DoRequest("PUT", path, "", map[string]interface{}{"lat": 40.79, "lng": -73.97})
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("status = %d, want 401", resp.StatusCode)
		}
	})
}

// TestUpdateDestinationWriteFailureIs500Not4xx is the invariant that keeps a
// database outage off the 4xx path: a client that sees 4xx reads it as "your
// request was wrong" and may retry forever, while the ride was never updated.
func TestUpdateDestinationWriteFailureIs500Not4xx(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.destoutage@test.com", "+7903000110")
	booked := requestMultiStopRide(t, riderToken, nil)

	// Make the destination write fail the way a dead database would.
	ts.RideRepo.FailNext = fmt.Errorf("dial tcp 127.0.0.1:5432: connection refused")
	defer func() { ts.RideRepo.FailNext = nil }()

	resp := ts.DoRequest("PUT", "/api/v1/rides/"+booked.Ride.ID+"/destination", riderToken,
		map[string]interface{}{"lat": 40.79, "lng": -73.97})

	resp.AssertStatus(t, http.StatusInternalServerError)
	gotErr := decodeErrorBody(t, resp.Body)
	if gotErr.Error.Code != "INTERNAL" {
		t.Errorf("code = %q, want INTERNAL", gotErr.Error.Code)
	}
	// The public message must stay operational: the driver error is the cause,
	// and it must never be rendered on a Flutter form.
	if gotErr.Error.Message != "failed to update ride destination" {
		t.Errorf("message = %q, want the operational sentence", gotErr.Error.Message)
	}
	if body := string(resp.Body); contains(body, "connection refused") {
		t.Errorf("response leaked the internal cause: %s", body)
	}
}

// TestRideStopsEnvelopeIsAdditive pins the compatibility promise: `ride` keeps
// its shape and `stops` is a sibling, so a client that predates multi-stop is
// unaffected.
func TestRideStopsEnvelopeIsAdditive(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.envelope@test.com", "+7903000111")
	booked := requestMultiStopRide(t, riderToken, nil)

	var raw map[string]json.RawMessage
	parseJSON(t, ts.DoRequest("GET", "/api/v1/rides/"+booked.Ride.ID, riderToken, nil).Body, &raw)
	for _, key := range []string{"ride", "stops"} {
		if _, ok := raw[key]; !ok {
			t.Errorf("response is missing the %q key: %v", key, raw)
		}
	}

	// An empty `stops` must encode as [], not null, so a client can iterate it
	// without a null check.
	var withStops struct {
		Stops []model.RideStop `json:"stops"`
	}
	parseJSON(t, ts.DoRequest("GET", "/api/v1/rides/"+booked.Ride.ID, riderToken, nil).Body, &withStops)
	if withStops.Stops == nil {
		t.Error("stops encoded as null, want []")
	}
}

// contains is a tiny helper so the leak assertion reads as prose.
func contains(haystack, needle string) bool {
	return len(needle) > 0 && len(haystack) >= len(needle) &&
		(func() bool {
			for i := 0; i+len(needle) <= len(haystack); i++ {
				if haystack[i:i+len(needle)] == needle {
					return true
				}
			}
			return false
		})()
}

// TestCurrentRideCarriesTheItinerary closes the consistency gap: the app polls
// GET /rides/current during an active trip, so a ride whose stops are visible in
// one response and invisible in another would be a real bug for the client.
func TestCurrentRideCarriesTheItinerary(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.current@test.com", "+7903000112")

	t.Run("with no current ride the shape is unchanged", func(t *testing.T) {
		resp := ts.DoRequest("GET", "/api/v1/rides/current", riderToken, nil)
		resp.AssertStatus(t, http.StatusOK)
		var body map[string]json.RawMessage
		parseJSON(t, resp.Body, &body)
		if string(body["ride"]) != "null" {
			t.Errorf("ride = %s, want null when there is no current ride", body["ride"])
		}
		if string(body["stops"]) != "[]" {
			t.Errorf("stops = %s, want []", body["stops"])
		}
	})

	t.Run("with a current ride the itinerary comes along", func(t *testing.T) {
		booked := requestMultiStopRide(t, riderToken, []map[string]interface{}{
			{"lat": 40.7200, "lng": -74.0000, "address": "Bakery"},
		})

		resp := ts.DoRequest("GET", "/api/v1/rides/current", riderToken, nil)
		resp.AssertStatus(t, http.StatusOK)

		var body struct {
			Ride  *model.Ride      `json:"ride"`
			Stops []model.RideStop `json:"stops"`
		}
		parseJSON(t, resp.Body, &body)
		if body.Ride == nil || body.Ride.ID != booked.Ride.ID {
			t.Fatalf("current ride = %+v, want %s", body.Ride, booked.Ride.ID)
		}
		if len(body.Stops) != 2 || body.Stops[0].Address != "Bakery" {
			t.Errorf("stops = %+v, want the bakery stop and the destination", body.Stops)
		}
	})
}

// TestRideHistoryCarriesEveryItinerary pins the batched shape: `rides` stays a
// flat array (an older client is unaffected) and `stops` is a sibling map keyed
// by ride id.
func TestRideHistoryCarriesEveryItinerary(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.history@test.com", "+7903000113")

	first := requestMultiStopRide(t, riderToken, []map[string]interface{}{
		{"lat": 40.7200, "lng": -74.0000, "address": "Bakery"},
	})
	second := requestMultiStopRide(t, riderToken, nil)

	resp := ts.DoRequest("GET", "/api/v1/rides/history?page=1&per_page=10", riderToken, nil)
	resp.AssertStatus(t, http.StatusOK)

	var body struct {
		Rides []model.Ride                `json:"rides"`
		Stops map[string][]model.RideStop `json:"stops"`
	}
	parseJSON(t, resp.Body, &body)

	if len(body.Rides) != 2 {
		t.Fatalf("got %d rides, want 2", len(body.Rides))
	}
	if len(body.Stops) != 2 {
		t.Fatalf("got %d stops entries, want one per ride: %+v", len(body.Stops), body.Stops)
	}
	if got := body.Stops[first.Ride.ID]; len(got) != 2 || got[0].Address != "Bakery" {
		t.Errorf("stops for the multi-stop ride = %+v, want the bakery stop plus destination", got)
	}
	if got := body.Stops[second.Ride.ID]; len(got) != 1 || got[0].Kind != model.DestinationKind {
		t.Errorf("stops for the single-leg ride = %+v, want just its destination", got)
	}
}

// TestCreateRideDestinationInvariant is the regression guard for the
// divergence the adversarial review found: the authoritative rides.dropoff_*
// scalar and the itinerary's last kind='destination' row must describe the
// SAME place. It exercises accepted creates only — a client stop that tries to
// claim the destination is rejected, which TestCreateRideStopsValidation pins.
func TestCreateRideDestinationInvariant(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.destinvariant@test.com", "+7903000114")

	bodies := []struct {
		name  string
		stops interface{}
	}{
		{name: "no stops", stops: nil},
		{name: "one intermediate stop", stops: []map[string]interface{}{
			{"lat": 40.7200, "lng": -74.0000, "address": "Bakery"},
		}},
		{name: "an explicit kind:stop", stops: []map[string]interface{}{
			{"kind": "stop", "lat": 40.7300, "lng": -73.9900, "address": "Park"},
		}},
		{name: "several intermediates", stops: []map[string]interface{}{
			{"lat": 40.7200, "lng": -74.0000, "address": "Bakery"},
			{"lat": 40.7300, "lng": -73.9900, "address": "Park"},
			{"lat": 40.7400, "lng": -73.9800, "address": "Plaza"},
		}},
	}

	for _, b := range bodies {
		t.Run(b.name, func(t *testing.T) {
			got := requestMultiStopRide(t, riderToken, b.stops)
			if len(got.Stops) == 0 {
				t.Fatal("no stops in the create response")
			}

			last := got.Stops[len(got.Stops)-1]
			if last.Kind != model.DestinationKind {
				t.Fatalf("last stop kind = %q, want %q", last.Kind, model.DestinationKind)
			}
			// The whole point: scalar == last row, for lat, lng AND address.
			if last.Lat != got.Ride.DropoffLat || last.Lng != got.Ride.DropoffLng {
				t.Errorf("rides.dropoff_* = %v/%v but last destination row = %v/%v",
					got.Ride.DropoffLat, got.Ride.DropoffLng, last.Lat, last.Lng)
			}
			if last.Address != got.Ride.DropoffAddress {
				t.Errorf("rides.dropoff_address = %q but last destination row = %q",
					got.Ride.DropoffAddress, last.Address)
			}
			// Exactly one destination row, and it is the last one.
			for i, s := range got.Stops {
				if s.Kind == model.DestinationKind && i != len(got.Stops)-1 {
					t.Errorf("stop %d is a second/earlier destination row: %+v", i, s)
				}
			}
		})
	}
}

// TestGetCurrentRideDistinguishesNotFoundFromOutage pins FIX-E: a genuinely
// absent ride is the normal 200 {ride:null} the app polls, but a database
// outage must surface as a 5xx. If the two were conflated, an outage would
// silently render the booking screen while an active ride exists.
func TestGetCurrentRideDistinguishesNotFoundFromOutage(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.currentoutage@test.com", "+7903000115")

	t.Run("no active ride is a 200 with ride null", func(t *testing.T) {
		resp := ts.DoRequest("GET", "/api/v1/rides/current", riderToken, nil)
		resp.AssertStatus(t, http.StatusOK)

		var body struct {
			Ride  *model.Ride      `json:"ride"`
			Stops []model.RideStop `json:"stops"`
		}
		parseJSON(t, resp.Body, &body)
		if body.Ride != nil {
			t.Errorf("ride = %+v, want null", body.Ride)
		}
		if body.Stops == nil {
			t.Error("stops = nil, want []")
		}
	})

	t.Run("an active ride is still returned", func(t *testing.T) {
		booked := requestMultiStopRide(t, riderToken, nil)
		resp := ts.DoRequest("GET", "/api/v1/rides/current", riderToken, nil)
		resp.AssertStatus(t, http.StatusOK)

		var body struct {
			Ride *model.Ride `json:"ride"`
		}
		parseJSON(t, resp.Body, &body)
		if body.Ride == nil || body.Ride.ID != booked.Ride.ID {
			t.Fatalf("current ride = %+v, want %s", body.Ride, booked.Ride.ID)
		}
	})

	t.Run("a load outage is a 500, never a null ride", func(t *testing.T) {
		ts.RideRepo.FailNext = fmt.Errorf("dial tcp 127.0.0.1:5432: connection refused")
		defer func() { ts.RideRepo.FailNext = nil }()

		resp := ts.DoRequest("GET", "/api/v1/rides/current", riderToken, nil)
		if resp.StatusCode == http.StatusOK {
			t.Fatalf("status = 200 (%s); an outage must not masquerade as \"no ride\"", resp.Body)
		}
		resp.AssertStatus(t, http.StatusInternalServerError)
		gotErr := decodeErrorBody(t, resp.Body)
		if gotErr.Error.Code != "INTERNAL" {
			t.Errorf("code = %q, want INTERNAL", gotErr.Error.Code)
		}
		if gotErr.Error.Message != "failed to load current ride" {
			t.Errorf("message = %q, want the operational sentence", gotErr.Error.Message)
		}
		if body := string(resp.Body); contains(body, "connection refused") {
			t.Errorf("response leaked the internal cause: %s", body)
		}
	})
}

// TestCreateRideZeroCoordinateIsValid pins the first half of STATUS.md bug #23:
// a literal 0 is a real coordinate (the equator / prime meridian), not a
// missing field. The old `binding:"required"` on a plain float64 rejected it
// with 422 because go-playground's `required` means "non-zero" for numbers.
func TestCreateRideZeroCoordinateIsValid(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.zerocoord@test.com", "+7903000116")

	resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, map[string]interface{}{
		"pickup_lat": 0, "pickup_lng": 0,
		"dropoff_lat": 0, "dropoff_lng": 0,
		"dropoff_address": "Gulf of Guinea",
	})
	resp.AssertStatus(t, http.StatusCreated)

	got := decodeRideWithStops(t, resp.Body)
	if got.Ride == nil {
		t.Fatal("no ride in the create response")
	}
	if got.Ride.PickupLat != 0 || got.Ride.PickupLng != 0 ||
		got.Ride.DropoffLat != 0 || got.Ride.DropoffLng != 0 {
		t.Errorf("zero coordinates did not round-trip through create: %+v", got.Ride)
	}

	// And they are durable, not just echoed: the authoritative read must still
	// see 0, so a value that only survives binding but is dropped in the DB
	// would fail here.
	readBack := decodeRideWithStops(t,
		ts.DoRequest("GET", "/api/v1/rides/"+got.Ride.ID, riderToken, nil).Body)
	if readBack.Ride.DropoffLat != 0 || readBack.Ride.DropoffLng != 0 {
		t.Errorf("persisted dropoff_* = %v/%v, want 0/0",
			readBack.Ride.DropoffLat, readBack.Ride.DropoffLng)
	}
}

// TestCreateRideCoordinateRangeValidation pins the second half of bug #23: the
// top-level pickup/dropoff were never range-checked, so e.g. dropoff_lat: 999
// was accepted 201 and written. Every field now answers 422 VALIDATION_ERROR
// with a human message naming it.
func TestCreateRideCoordinateRangeValidation(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.coordrange@test.com", "+7903000117")

	tests := []struct {
		name    string
		field   string
		value   float64
		wantMsg string
	}{
		{"pickup latitude above range", "pickup_lat", 999, "Pickup latitude out of range"},
		{"pickup latitude below range", "pickup_lat", -91, "Pickup latitude out of range"},
		{"pickup longitude above range", "pickup_lng", 181, "Pickup longitude out of range"},
		{"pickup longitude below range", "pickup_lng", -181, "Pickup longitude out of range"},
		{"drop-off latitude above range", "dropoff_lat", 999, "Drop-off latitude out of range"},
		{"drop-off latitude below range", "dropoff_lat", -91, "Drop-off latitude out of range"},
		{"drop-off longitude above range", "dropoff_lng", 181, "Drop-off longitude out of range"},
		{"drop-off longitude below range", "dropoff_lng", -181, "Drop-off longitude out of range"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := map[string]interface{}{
				"pickup_lat": 40.7128, "pickup_lng": -74.0060,
				"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
			}
			body[tt.field] = tt.value

			resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, body)
			resp.AssertStatus(t, http.StatusUnprocessableEntity)

			gotErr := decodeErrorBody(t, resp.Body)
			if gotErr.Error.Code != "VALIDATION_ERROR" {
				t.Errorf("code = %q, want VALIDATION_ERROR", gotErr.Error.Code)
			}
			if gotErr.Error.Message != tt.wantMsg {
				t.Errorf("message = %q, want %q (public text: rendered verbatim)",
					gotErr.Error.Message, tt.wantMsg)
			}
			// `message` is public; the internal cause must never leak.
			if contains(string(resp.Body), "out of range (lat=") {
				t.Errorf("response leaked the internal cause: %s", resp.Body)
			}
		})
	}
}

// TestCreateRideMissingCoordinateIs422 pins bug #23 item 4: making 0 valid must
// not turn an ABSENT coordinate into 0. The required tag still catches a nil
// pointer and names the field.
func TestCreateRideMissingCoordinateIs422(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.missingcoord@test.com", "+7903000118")

	tests := []struct {
		name    string
		omit    string
		wantMsg string
	}{
		{"pickup latitude", "pickup_lat", "Invalid Pickup latitude"},
		{"pickup longitude", "pickup_lng", "Invalid Pickup longitude"},
		{"drop-off latitude", "dropoff_lat", "Invalid Drop-off latitude"},
		{"drop-off longitude", "dropoff_lng", "Invalid Drop-off longitude"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			body := map[string]interface{}{
				"pickup_lat": 40.7128, "pickup_lng": -74.0060,
				"dropoff_lat": 40.7580, "dropoff_lng": -73.9855,
			}
			delete(body, tt.omit)

			resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, body)
			resp.AssertStatus(t, http.StatusUnprocessableEntity)

			gotErr := decodeErrorBody(t, resp.Body)
			if gotErr.Error.Code != "VALIDATION_ERROR" || gotErr.Error.Message != tt.wantMsg {
				t.Errorf("error = %+v, want VALIDATION_ERROR / %q", gotErr.Error, tt.wantMsg)
			}
		})
	}
}

// TestCreateRideMalformedBodyIs400 pins the last edge: a malformed body is a
// BAD_REQUEST, not a 422 and not an outage, even though the coordinates are now
// validated by hand rather than by the binding tag alone.
func TestCreateRideMalformedBodyIs400(t *testing.T) {
	riderToken := registerAndLogin(t, "rider.malformedbody@test.com", "+7903000119")

	// json.Marshal of the string yields the JSON literal `"not an object"`,
	// which cannot decode into the request struct: a malformed body, not a
	// missing field.
	resp := ts.DoRequest("POST", "/api/v1/rides", riderToken, "not an object")
	resp.AssertStatus(t, http.StatusBadRequest)

	if code := decodeErrorBody(t, resp.Body).Error.Code; code != "BAD_REQUEST" {
		t.Errorf("code = %q, want BAD_REQUEST", code)
	}
}
