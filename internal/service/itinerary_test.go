package service

import (
	"strings"
	"testing"

	"ride-hailing-api/internal/model"
)

// TestBuildItinerary pins the itinerary contract of
// api_plans/[multi]_add_stops_change_destination.md.
//
// The invariant under test is the one the adversarial review broke: the final
// destination is defined SOLELY by the top-level dropoff, so the last row must
// always equal those coords, and a client stop may never claim to be the
// destination. Each case says what a client could get wrong and what the API
// must answer, so a regression names the bug it would reintroduce.
func TestBuildItinerary(t *testing.T) {
	const (
		destLat = 40.7580
		destLng = -73.9855
		destAdr = "Rua Augusta, 500"
	)

	tests := []struct {
		name  string
		stops []StopInput
		want  []model.RideStop
		// wantErr is a substring of the public message; empty means success.
		wantErr string
	}{
		{
			name:  "no stops still ends at the ride's own dropoff",
			stops: nil,
			want: []model.RideStop{
				{Sequence: 1, Kind: model.DestinationKind, Lat: destLat, Lng: destLng, Address: destAdr},
			},
		},
		{
			name:  "intermediate stops keep array order and gain 1-based sequences",
			stops: []StopInput{{Lat: 1, Lng: 2}, {Lat: 3, Lng: 4}},
			want: []model.RideStop{
				{Sequence: 1, Kind: model.StopKind, Lat: 1, Lng: 2},
				{Sequence: 2, Kind: model.StopKind, Lat: 3, Lng: 4},
				{Sequence: 3, Kind: model.DestinationKind, Lat: destLat, Lng: destLng, Address: destAdr},
			},
		},
		{
			name: "an explicit kind:\"stop\" is accepted",
			stops: []StopInput{
				{Kind: model.StopKind, Lat: 1, Lng: 2, Address: "Bakery"},
			},
			want: []model.RideStop{
				{Sequence: 1, Kind: model.StopKind, Lat: 1, Lng: 2, Address: "Bakery"},
				{Sequence: 2, Kind: model.DestinationKind, Lat: destLat, Lng: destLng, Address: destAdr},
			},
		},
		{
			name:  "the equator and the antimeridian are valid coordinates",
			stops: []StopInput{{Lat: 0, Lng: 0}, {Lat: 0, Lng: 180}},
			want: []model.RideStop{
				{Sequence: 1, Kind: model.StopKind, Lat: 0, Lng: 0},
				{Sequence: 2, Kind: model.StopKind, Lat: 0, Lng: 180},
				{Sequence: 3, Kind: model.DestinationKind, Lat: destLat, Lng: destLng, Address: destAdr},
			},
		},
		{
			// The divergence the review found: the stop's coords used to become
			// the last row while rides.dropoff_* kept the top-level ones.
			name:    "a client stop may not claim the destination",
			stops:   []StopInput{{Kind: model.DestinationKind, Lat: 9, Lng: 9, Address: "Office"}},
			wantErr: "the final destination is set by dropoff_lat/dropoff_lng/dropoff_address",
		},
		{
			name: "even a destination stop sent last is rejected",
			stops: []StopInput{
				{Lat: 1, Lng: 2},
				{Kind: model.DestinationKind, Lat: 9, Lng: 9},
			},
			wantErr: "stop 2: the final destination is set by",
		},
		{
			name:    "an unknown kind is rejected, not coerced",
			stops:   []StopInput{{Kind: "waypoint", Lat: 1, Lng: 1}},
			wantErr: `kind must be omitted or "stop"`,
		},
		{
			name:    "latitude out of range is rejected",
			stops:   []StopInput{{Lat: 91, Lng: 1}},
			wantErr: "latitude out of range",
		},
		{
			name:    "longitude out of range is rejected",
			stops:   []StopInput{{Lat: 1, Lng: -181}},
			wantErr: "longitude out of range",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := BuildItinerary(tt.stops, destLat, destLng, destAdr)
			if tt.wantErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got itinerary %+v", tt.wantErr, got)
				}
				if !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %q, want it to contain %q", err.Error(), tt.wantErr)
				}
				// A rejection is a client problem, so the handler must be able
				// to answer 422 and may expose Message verbatim.
				if _, ok := err.(*ValidationError); !ok {
					t.Errorf("error type = %T, want *ValidationError", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("itinerary length = %d, want %d (%+v)", len(got), len(tt.want), got)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("stop %d = %+v, want %+v", i, got[i], tt.want[i])
				}
			}

			// THE INVARIANT: every accepted itinerary ends in exactly one
			// destination row that equals the top-level dropoff, which is what
			// rides.dropoff_* stores. No accepted input may break this.
			last := got[len(got)-1]
			if last.Kind != model.DestinationKind {
				t.Fatalf("last stop kind = %q, want %q", last.Kind, model.DestinationKind)
			}
			if last.Lat != destLat || last.Lng != destLng || last.Address != destAdr {
				t.Errorf("last stop = %+v, want the top-level dropoff %v/%v/%q",
					last, destLat, destLng, destAdr)
			}
			// And no earlier row may also be a destination.
			for i := 0; i < len(got)-1; i++ {
				if got[i].Kind == model.DestinationKind {
					t.Errorf("stop %d is a second destination row: %+v", i, got[i])
				}
			}
		})
	}
}

// TestBuildItineraryDestinationNeverDivergesFromDropoff is the direct
// regression for the divergence bug: whatever stops are accepted, the last row
// carries the top-level dropoff, including when a client sends coordinates that
// differ from it.
func TestBuildItineraryDestinationNeverDivergesFromDropoff(t *testing.T) {
	got, err := BuildItinerary([]StopInput{{Lat: 1, Lng: 2, Address: "Bakery"}}, 40.7580, -73.9855, "Top-level dropoff")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	last := got[len(got)-1]
	if last.Lat != 40.7580 || last.Lng != -73.9855 || last.Address != "Top-level dropoff" {
		t.Fatalf("last row = %+v, want the top-level dropoff", last)
	}
}

// TestBuildItineraryErrorNamesTheOffendingStop proves the public message can
// be acted on: "stop 3" is useless if the client sent four.
func TestBuildItineraryErrorNamesTheOffendingStop(t *testing.T) {
	_, err := BuildItinerary([]StopInput{{Lat: 1, Lng: 1}, {Lat: 2, Lng: 2}, {Lat: 99, Lng: 2}}, 0, 0, "")
	if err == nil {
		t.Fatal("expected an error for the out-of-range third stop")
	}
	if !strings.Contains(err.Error(), "stop 3") {
		t.Errorf("error = %q, want it to name stop 3", err.Error())
	}
}
