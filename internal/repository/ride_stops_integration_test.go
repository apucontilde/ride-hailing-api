//go:build integration

package repository

import (
	"errors"
	"testing"

	"ride-hailing-api/internal/model"
)

// TestRideStopsSQLIntegration exercises the real SQL of migration 016 against a
// live DB: CreateRide's stop transaction, FindStopsByRideID's ordering, and
// ReplaceDestination's update-in-place.
//
// The fixtures are TEMP tables on a single-connection handle (the trick the
// routing/ratings integration tests here use), so unqualified `rides` /
// `ride_stops` references resolve to the fixture and the real tables are never
// touched. The CHECK and UNIQUE constraints are reproduced verbatim, which is
// the part a mock cannot prove.
func TestRideStopsSQLIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS ride_stops") })
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS rides") })

	mustExec(t, db, `CREATE TEMP TABLE rides (
		id                UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
		rider_id          UUID          NOT NULL,
		driver_id         UUID,
		status            TEXT          NOT NULL DEFAULT 'pending',
		pickup_lat        DOUBLE PRECISION NOT NULL,
		pickup_lng        DOUBLE PRECISION NOT NULL,
		dropoff_lat       DOUBLE PRECISION NOT NULL,
		dropoff_lng       DOUBLE PRECISION NOT NULL,
		pickup_address    TEXT          NOT NULL DEFAULT '',
		dropoff_address   TEXT          NOT NULL DEFAULT '',
		vehicle_type      TEXT          NOT NULL DEFAULT 'sedan',
		cancellation_fee  DOUBLE PRECISION NOT NULL DEFAULT 0,
		idempotency_key   TEXT          NOT NULL DEFAULT '',
		base_fare         DOUBLE PRECISION NOT NULL DEFAULT 0,
		distance_fare     DOUBLE PRECISION NOT NULL DEFAULT 0,
		time_fare         DOUBLE PRECISION NOT NULL DEFAULT 0,
		surge_multiplier  DOUBLE PRECISION NOT NULL DEFAULT 1.0,
		total_fare        DOUBLE PRECISION NOT NULL DEFAULT 0,
		fare_region_id    TEXT,
		fare_rate_id      UUID,
		fare_currency     TEXT,
		grade_uplift_pct  NUMERIC(6,4),
		grade_ascent_m    DOUBLE PRECISION,
		requested_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
		accepted_at       TIMESTAMPTZ,
		driver_arrived_at TIMESTAMPTZ,
		started_at        TIMESTAMPTZ,
		completed_at      TIMESTAMPTZ,
		cancelled_at      TIMESTAMPTZ,
		created_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
		updated_at        TIMESTAMPTZ   NOT NULL DEFAULT NOW()
	)`)
	mustExec(t, db, `CREATE TEMP TABLE ride_stops (
		id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
		ride_id    UUID        NOT NULL,
		sequence   INTEGER     NOT NULL CHECK (sequence >= 1),
		kind       TEXT        NOT NULL DEFAULT 'stop' CHECK (kind IN ('stop','destination')),
		lat        DOUBLE PRECISION NOT NULL,
		lng        DOUBLE PRECISION NOT NULL,
		address    TEXT        NOT NULL DEFAULT '',
		created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		UNIQUE (ride_id, sequence)
	)`)

	const (
		rider1  = "11111111-1111-1111-1111-111111111111"
		rider2  = "22222222-2222-2222-2222-222222222222"
		ride1   = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
		ride2   = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
		noStops = "cccccccc-cccc-cccc-cccc-cccccccccccc"
	)
	mustExec(t, db, `INSERT INTO rides
		(id, rider_id, status, pickup_lat, pickup_lng, dropoff_lat, dropoff_lng, dropoff_address) VALUES
		($1, $2, 'pending', 40.7128, -74.0060, 40.7580, -73.9855, 'Original destination'),
		($3, $4, 'pending', 40.7128, -74.0060, 40.7580, -73.9855, 'Other rider ride'),
		($5, $2, 'pending', 1.0, 1.0, 2.0, 2.0, '')`,
		ride1, rider1, ride2, rider2, noStops)

	repo := NewRideRepo(db)

	t.Run("stops come back in visit order regardless of insertion order", func(t *testing.T) {
		// Inserted 3, 1, 2 so an unsorted read cannot pass by luck.
		mustExec(t, db, `INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng, address) VALUES
			($1, 3, 'destination', 40.7580, -73.9855, 'Original destination'),
			($1, 1, 'stop',        40.7200, -74.0000, 'Bakery'),
			($1, 2, 'stop',        40.7300, -73.9900, 'Park'),
			($2, 1, 'destination', 40.7580, -73.9855, 'Other rider ride')`,
			ride1, ride2)

		stops, err := repo.FindStopsByRideID(ride1)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		if len(stops) != 3 {
			t.Fatalf("got %d stops, want 3: %+v", len(stops), stops)
		}
		wantAddr := []string{"Bakery", "Park", "Original destination"}
		wantKind := []string{model.StopKind, model.StopKind, model.DestinationKind}
		for i := range stops {
			if stops[i].Sequence != i+1 {
				t.Errorf("stops[%d].Sequence = %d, want %d", i, stops[i].Sequence, i+1)
			}
			if stops[i].Address != wantAddr[i] {
				t.Errorf("stops[%d].Address = %q, want %q", i, stops[i].Address, wantAddr[i])
			}
			if stops[i].Kind != wantKind[i] {
				t.Errorf("stops[%d].Kind = %q, want %q", i, stops[i].Kind, wantKind[i])
			}
			if stops[i].RideID != ride1 {
				t.Errorf("stops[%d].RideID = %q, want %q", i, stops[i].RideID, ride1)
			}
			if stops[i].ID == "" {
				t.Errorf("stops[%d].ID is empty", i)
			}
		}
	})

	t.Run("a ride with no stops answers empty, not nil", func(t *testing.T) {
		stops, err := repo.FindStopsByRideID(noStops)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		if stops == nil {
			t.Error("stops = nil, want an empty slice so JSON encodes [] and not null")
		}
		if len(stops) != 0 {
			t.Errorf("got %d stops, want 0", len(stops))
		}
	})

	t.Run("CreateRide persists the itinerary in one transaction", func(t *testing.T) {
		// The repository generates the ride id, so the stops must be found
		// under the id it wrote back — not under one this test chose.
		ride := &model.Ride{
			RiderID: rider1, Status: "pending",
			PickupLat: 40.7128, PickupLng: -74.0060,
			DropoffLat: 40.7580, DropoffLng: -73.9855, DropoffAddress: "Original destination",
			Stops: []model.RideStop{
				{Sequence: 1, Kind: model.StopKind, Lat: 40.72, Lng: -74.0, Address: "Bakery"},
				{Sequence: 2, Kind: model.DestinationKind, Lat: 40.758, Lng: -73.9855, Address: "Original destination"},
			},
		}
		if err := repo.CreateRide(ride); err != nil {
			t.Fatalf("CreateRide: %v", err)
		}
		if ride.ID == "" {
			t.Fatal("CreateRide did not fill in the ride id")
		}

		stops, err := repo.FindStopsByRideID(ride.ID)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		if len(stops) != 2 {
			t.Fatalf("got %d stops, want 2: %+v", len(stops), stops)
		}
		for _, s := range stops {
			if s.RideID != ride.ID {
				t.Errorf("stop ride_id = %q, want %q", s.RideID, ride.ID)
			}
			if s.ID == "" {
				t.Error("stop ID was not filled in by the insert")
			}
			if s.CreatedAt.IsZero() {
				t.Error("stop created_at was not filled in by the insert")
			}
		}

		// The divergence regression, at the DB level: the authoritative
		// rides.dropoff_* scalar and the last kind='destination' row must be
		// the same place. If CreateRide persisted two different truths, a
		// receipt or route built from the scalar would disagree with the
		// itinerary the rider sees.
		var rideRow model.Ride
		if err := db.Get(&rideRow, `SELECT * FROM rides WHERE id = $1`, ride.ID); err != nil {
			t.Fatalf("reading back the ride: %v", err)
		}
		last := stops[len(stops)-1]
		if last.Kind != model.DestinationKind {
			t.Fatalf("last stop kind = %q, want %q", last.Kind, model.DestinationKind)
		}
		if rideRow.DropoffLat != last.Lat || rideRow.DropoffLng != last.Lng {
			t.Errorf("rides.dropoff_* = %v/%v but last destination row = %v/%v",
				rideRow.DropoffLat, rideRow.DropoffLng, last.Lat, last.Lng)
		}
		if rideRow.DropoffAddress != last.Address {
			t.Errorf("rides.dropoff_address = %q but last destination row = %q",
				rideRow.DropoffAddress, last.Address)
		}
	})

	t.Run("CreateRide still books a ride that carries no stops at all", func(t *testing.T) {
		// The pre-016 path must keep working after the transaction was unified:
		// a client that never heard of stops gets exactly the ride it got before.
		ride := &model.Ride{
			RiderID: rider1, Status: "pending",
			PickupLat: 40.7128, PickupLng: -74.0060,
			DropoffLat: 40.758, DropoffLng: -73.9855,
		}
		if err := repo.CreateRide(ride); err != nil {
			t.Fatalf("CreateRide without stops: %v", err)
		}
		if ride.ID == "" || ride.Status != "pending" {
			t.Errorf("ride = %+v, want an id and status pending filled in", ride)
		}
		stops, err := repo.FindStopsByRideID(ride.ID)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		if len(stops) != 0 {
			t.Errorf("stops = %+v, want none: the service always sends a destination", stops)
		}
	})

	t.Run("CreateRide rolls the whole ride back when one stop is invalid", func(t *testing.T) {
		ride := &model.Ride{
			RiderID: rider1, Status: "pending",
			PickupLat: 1, PickupLng: 1, DropoffLat: 2, DropoffLng: 2,
			Stops: []model.RideStop{
				{Sequence: 1, Kind: model.StopKind, Lat: 3, Lng: 3},
				// sequence 1 again: violates UNIQUE(ride_id, sequence).
				{Sequence: 1, Kind: model.StopKind, Lat: 4, Lng: 4},
			},
		}
		if err := repo.CreateRide(ride); err == nil {
			t.Fatal("expected the second stop to violate UNIQUE(ride_id, sequence)")
		}

		// The atomicity claim: a half-booked ride would be worse than none.
		var count int
		if err := db.Get(&count, `SELECT count(*) FROM rides WHERE id = $1`, ride.ID); err != nil {
			t.Fatalf("counting rides: %v", err)
		}
		if count != 0 {
			t.Errorf("the ride row survived a failed stop insert: %d rows, want 0", count)
		}
		if err := db.Get(&count, `SELECT count(*) FROM ride_stops WHERE ride_id = $1`, ride.ID); err != nil {
			t.Fatalf("counting stops: %v", err)
		}
		if count != 0 {
			t.Errorf("orphan stops survived a rolled-back ride: %d rows, want 0", count)
		}
	})

	t.Run("ReplaceDestination moves the existing destination row", func(t *testing.T) {
		before, err := repo.FindStopsByRideID(ride1)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		destID := ""
		for _, s := range before {
			if s.Kind == model.DestinationKind {
				destID = s.ID
			}
		}

		if err := repo.ReplaceDestination(ride1, model.RideStop{
			Kind: model.DestinationKind, Lat: 40.79, Lng: -73.97, Address: "New destination",
		}); err != nil {
			t.Fatalf("ReplaceDestination: %v", err)
		}

		after, err := repo.FindStopsByRideID(ride1)
		if err != nil {
			t.Fatalf("FindStopsByRideID after: %v", err)
		}
		if len(after) != 3 {
			t.Fatalf("got %d stops, want 3: a change must not append or drop stops", len(after))
		}
		last := after[len(after)-1]
		if last.Kind != model.DestinationKind || last.Lat != 40.79 || last.Lng != -73.97 {
			t.Errorf("last stop = %+v, want the new destination", last)
		}
		if last.Address != "New destination" {
			t.Errorf("last.Address = %q, want %q", last.Address, "New destination")
		}
		if last.ID != destID {
			t.Errorf("destination row id changed (%s -> %s): it must be UPDATED in place", destID, last.ID)
		}
		if after[0].Address != "Bakery" || after[1].Address != "Park" {
			t.Errorf("intermediate stops were disturbed: %+v", after)
		}

		// The scalars rides.dropoff_* moved too — that mirror is the whole point.
		var ride model.Ride
		if err := db.Get(&ride, `SELECT * FROM rides WHERE id = $1`, ride1); err != nil {
			t.Fatalf("reading back the ride: %v", err)
		}
		if ride.DropoffLat != 40.79 || ride.DropoffLng != -73.97 || ride.DropoffAddress != "New destination" {
			t.Errorf("rides.dropoff_* = %v/%v/%q, want the new destination",
				ride.DropoffLat, ride.DropoffLng, ride.DropoffAddress)
		}
		if ride.Status != "pending" {
			t.Errorf("status = %q, want pending: the repository must not transition", ride.Status)
		}
	})

	t.Run("ReplaceDestination appends a destination when the ride has none", func(t *testing.T) {
		if err := repo.ReplaceDestination(noStops, model.RideStop{
			Kind: model.DestinationKind, Lat: 9.5, Lng: 9.5, Address: "Appended",
		}); err != nil {
			t.Fatalf("ReplaceDestination: %v", err)
		}
		stops, err := repo.FindStopsByRideID(noStops)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		if len(stops) != 1 {
			t.Fatalf("got %d stops, want exactly the appended one: %+v", len(stops), stops)
		}
		if stops[0].Sequence != 1 || stops[0].Kind != model.DestinationKind {
			t.Errorf("appended stop = %+v, want sequence 1 / destination", stops[0])
		}
	})

	t.Run("an unknown ride is a not-found classification", func(t *testing.T) {
		err := repo.ReplaceDestination("dddddddd-dddd-dddd-dddd-dddddddddddd", model.RideStop{
			Kind: model.DestinationKind, Lat: 1, Lng: 1,
		})
		if !errors.Is(err, ErrNotFound) {
			t.Fatalf("error = %v, want ErrNotFound (the handler maps it to 404)", err)
		}
	})

	t.Run("the constraints reject what the service would never send", func(t *testing.T) {
		if _, err := db.Exec(
			`INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng) VALUES ($1, 1, 'stop', 1, 1)`,
			ride1); err == nil {
			t.Error("a duplicate (ride_id, sequence) was accepted")
		}
		if _, err := db.Exec(
			`INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng) VALUES ($1, 0, 'stop', 1, 1)`,
			ride2); err == nil {
			t.Error("sequence 0 was accepted")
		}
		if _, err := db.Exec(
			`INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng) VALUES ($1, 7, 'waypoint', 1, 1)`,
			ride2); err == nil {
			t.Error(`kind="waypoint" was accepted`)
		}
	})

	t.Run("a ride's stops are private to that ride", func(t *testing.T) {
		stops, err := repo.FindStopsByRideID(ride2)
		if err != nil {
			t.Fatalf("FindStopsByRideID: %v", err)
		}
		if len(stops) != 1 {
			t.Errorf("got %d stops for ride2, want 1", len(stops))
		}
		for _, s := range stops {
			if s.RideID != ride2 {
				t.Errorf("leaked a stop from another ride: %+v", s)
			}
		}
	})
}

// TestFindStopsByRideIDsIntegration covers the batched history query: one round
// trip, every requested ride present, no leakage between rides, and no
// `IN ()` blow-up on an empty page.
func TestFindStopsByRideIDsIntegration(t *testing.T) {
	db := connectPG(t)
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _, _ = db.Exec("DROP TABLE IF EXISTS ride_stops") })

	mustExec(t, db, `CREATE TEMP TABLE ride_stops (
		id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
		ride_id    UUID        NOT NULL,
		sequence   INTEGER     NOT NULL CHECK (sequence >= 1),
		kind       TEXT        NOT NULL DEFAULT 'stop' CHECK (kind IN ('stop','destination')),
		lat        DOUBLE PRECISION NOT NULL,
		lng        DOUBLE PRECISION NOT NULL,
		address    TEXT        NOT NULL DEFAULT '',
		created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
		UNIQUE (ride_id, sequence)
	)`)

	const (
		rideA = "11111111-1111-1111-1111-111111111111"
		rideB = "22222222-2222-2222-2222-222222222222"
		rideC = "33333333-3333-3333-3333-333333333333"
	)
	mustExec(t, db, `INSERT INTO ride_stops (ride_id, sequence, kind, lat, lng, address) VALUES
		($1, 2, 'destination', 40.758, -73.985, 'B destination'),
		($1, 1, 'stop',        40.720, -74.000, 'B first'),
		($2, 1, 'destination', 40.700, -73.900, 'C destination')`, rideA, rideB)

	repo := NewRideRepo(db)

	t.Run("every requested ride is present, empty ones included", func(t *testing.T) {
		got, err := repo.FindStopsByRideIDs([]string{rideA, rideB, rideC})
		if err != nil {
			t.Fatalf("FindStopsByRideIDs: %v", err)
		}
		if len(got) != 3 {
			t.Fatalf("got %d entries, want 3 (rideC has no stops but must be present): %+v", len(got), got)
		}
		empty, ok := got[rideC]
		if !ok {
			t.Fatal("rideC is missing from the map, so a caller would need a presence check")
		}
		if empty == nil || len(empty) != 0 {
			t.Errorf("rideC = %+v, want an empty (non-nil) slice", empty)
		}
	})

	t.Run("each ride keeps its own ordered itinerary", func(t *testing.T) {
		got, err := repo.FindStopsByRideIDs([]string{rideA, rideB})
		if err != nil {
			t.Fatalf("FindStopsByRideIDs: %v", err)
		}
		if len(got[rideA]) != 2 || got[rideA][0].Address != "B first" || got[rideA][1].Address != "B destination" {
			t.Errorf("rideA stops = %+v, want [B first, B destination] in order", got[rideA])
		}
		if len(got[rideB]) != 1 || got[rideB][0].RideID != rideB {
			t.Errorf("rideB stops = %+v, want just its own destination", got[rideB])
		}
		for _, s := range got[rideA] {
			if s.RideID != rideA {
				t.Errorf("rideA map entry holds a stop from %s", s.RideID)
			}
		}
	})

	t.Run("an unrequested ride never leaks in", func(t *testing.T) {
		got, err := repo.FindStopsByRideIDs([]string{rideB})
		if err != nil {
			t.Fatalf("FindStopsByRideIDs: %v", err)
		}
		if _, leaked := got[rideA]; leaked {
			t.Error("rideA appeared in a query that only asked for rideB")
		}
	})

	t.Run("an empty page answers an empty map without a query", func(t *testing.T) {
		got, err := repo.FindStopsByRideIDs(nil)
		if err != nil {
			t.Fatalf("FindStopsByRideIDs(nil): %v", err)
		}
		if len(got) != 0 {
			t.Errorf("got %+v, want an empty map", got)
		}
		got, err = repo.FindStopsByRideIDs([]string{})
		if err != nil {
			t.Fatalf("FindStopsByRideIDs([]): %v", err)
		}
		if len(got) != 0 {
			t.Errorf("got %+v, want an empty map", got)
		}
	})
}
