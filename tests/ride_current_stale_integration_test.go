//go:build integration

package tests

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/handler"
	"ride-hailing-api/internal/model"
	"ride-hailing-api/internal/repository"
)

// This file owns a DB connection: package tests is otherwise mock/db=nil, so
// the real FindCurrentRideByRider age guard (api_plans
// [rides]_orphaned_pending_expiry.md D4) needs its own TEMP `rides` and
// `ride_stops` tables. The success path calls FindStopsByRideID, so the stops
// table must exist even when it is empty.

func staleRideTestDB(t *testing.T) *sqlx.DB {
	t.Helper()
	db, err := sqlx.Connect("postgres", config.Load().DatabaseURL())
	if err != nil {
		t.Skipf("no database available (need `docker compose up -d`): %v", err)
	}
	db.SetMaxOpenConns(1) // TEMP tables must stay visible to every repo query
	t.Cleanup(func() { _ = db.Close() })
	for _, ddl := range []string{
		`CREATE TEMP TABLE rides (
			id                      UUID          PRIMARY KEY DEFAULT uuid_generate_v4(),
			rider_id                UUID          NOT NULL,
			driver_id               UUID,
			status                  TEXT          NOT NULL DEFAULT 'pending',
			pickup_lat              DOUBLE PRECISION NOT NULL,
			pickup_lng              DOUBLE PRECISION NOT NULL,
			dropoff_lat             DOUBLE PRECISION NOT NULL,
			dropoff_lng             DOUBLE PRECISION NOT NULL,
			pickup_address          TEXT          NOT NULL DEFAULT '',
			dropoff_address         TEXT          NOT NULL DEFAULT '',
			vehicle_type            TEXT          NOT NULL DEFAULT 'sedan',
			cancellation_fee        DOUBLE PRECISION NOT NULL DEFAULT 0,
			idempotency_key         TEXT          NOT NULL DEFAULT '',
			base_fare               DOUBLE PRECISION NOT NULL DEFAULT 0,
			distance_fare           DOUBLE PRECISION NOT NULL DEFAULT 0,
			time_fare               DOUBLE PRECISION NOT NULL DEFAULT 0,
			surge_multiplier        DOUBLE PRECISION NOT NULL DEFAULT 1.0,
			total_fare              DOUBLE PRECISION NOT NULL DEFAULT 0,
			fare_region_id          TEXT,
			fare_rate_id            UUID,
			fare_currency           TEXT,
			grade_uplift_pct        NUMERIC(6,4),
			grade_ascent_m          DOUBLE PRECISION,
			actual_duration_s       INTEGER,
			actual_distance_m       DOUBLE PRECISION,
			quoted_base_fare        DOUBLE PRECISION,
			quoted_distance_fare    DOUBLE PRECISION,
			quoted_time_fare        DOUBLE PRECISION,
			quoted_surge_multiplier DOUBLE PRECISION,
			quoted_total_fare       DOUBLE PRECISION,
			quoted_grade_uplift_pct NUMERIC(6,4),
			requested_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
			accepted_at             TIMESTAMPTZ,
			driver_arrived_at       TIMESTAMPTZ,
			started_at              TIMESTAMPTZ,
			completed_at            TIMESTAMPTZ,
			cancelled_at            TIMESTAMPTZ,
			created_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
			updated_at              TIMESTAMPTZ   NOT NULL DEFAULT NOW()
		)`,
		`CREATE TEMP TABLE ride_stops (
			id         UUID        PRIMARY KEY DEFAULT uuid_generate_v4(),
			ride_id    UUID        NOT NULL,
			sequence   INTEGER     NOT NULL,
			kind       TEXT        NOT NULL DEFAULT 'stop',
			lat        DOUBLE PRECISION NOT NULL,
			lng        DOUBLE PRECISION NOT NULL,
			address    TEXT        NOT NULL DEFAULT '',
			created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
			updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
		)`,
	} {
		if _, err := db.Exec(ddl); err != nil {
			t.Fatalf("fixture DDL failed: %v\n%s", err, ddl)
		}
	}
	t.Cleanup(func() {
		_, _ = db.Exec(`DROP TABLE IF EXISTS ride_stops`)
		_, _ = db.Exec(`DROP TABLE IF EXISTS rides`)
	})
	return db
}

func currentRideEngine(db *sqlx.DB, riderID string) *gin.Engine {
	repo := repository.NewRideRepo(db, repository.WithPendingStaleAfter(10*time.Minute))
	h := handler.NewRideHandler(nil, nil, repo, 8)

	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(func(c *gin.Context) {
		c.Set("user_id", riderID)
		c.Set("role", "rider")
		c.Next()
	})
	r.GET("/rides/current", h.GetCurrentRide)
	return r
}

func getCurrentRide(t *testing.T, r *gin.Engine) (int, *model.Ride, []model.RideStop, []byte) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/rides/current", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	var body struct {
		Ride  *model.Ride      `json:"ride"`
		Stops []model.RideStop `json:"stops"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", w.Body.String(), err)
	}
	return w.Code, body.Ride, body.Stops, w.Body.Bytes()
}

func seedCurrentRide(t *testing.T, db *sqlx.DB, id, riderID, status, age string) {
	t.Helper()
	if _, err := db.Exec(`
		INSERT INTO rides (id, rider_id, status, pickup_lat, pickup_lng,
			dropoff_lat, dropoff_lng, created_at, updated_at)
		VALUES ($1, $2, $3, 9.93, -84.08, 9.94, -84.07,
			NOW() - $4::interval, NOW() - $4::interval)`,
		id, riderID, status, age); err != nil {
		t.Fatalf("seed ride: %v", err)
	}
}

func TestGetCurrentRideHidesStalePending(t *testing.T) {
	db := staleRideTestDB(t)
	const (
		rider = "77777777-7777-7777-7777-777777777777"
		ride  = "16161616-1616-1616-1616-161616161616"
	)
	seedCurrentRide(t, db, ride, rider, "pending", "11 minutes")

	code, gotRide, stops, raw := getCurrentRide(t, currentRideEngine(db, rider))
	if code != http.StatusOK {
		t.Fatalf("status = %d (%s), want 200", code, raw)
	}
	if gotRide != nil {
		t.Errorf("ride = %+v, want null for a stale pending ride", gotRide)
	}
	if stops == nil {
		t.Errorf("stops = null in %s, want an empty array", raw)
	}
	if len(stops) != 0 {
		t.Errorf("stops = %+v, want []", stops)
	}
	if string(raw) != `{"ride":null,"stops":[]}` {
		t.Errorf("body = %s, want the documented {\"ride\":null,\"stops\":[]}", raw)
	}
}

func TestGetCurrentRideStillReturnsFreshPending(t *testing.T) {
	db := staleRideTestDB(t)
	const (
		rider = "88888888-8888-8888-8888-888888888888"
		ride  = "17171717-1717-1717-1717-171717171717"
	)
	seedCurrentRide(t, db, ride, rider, "pending", "0 seconds")

	code, gotRide, stops, raw := getCurrentRide(t, currentRideEngine(db, rider))
	if code != http.StatusOK {
		t.Fatalf("status = %d (%s), want 200", code, raw)
	}
	if gotRide == nil || gotRide.ID != ride || gotRide.Status != "pending" {
		t.Fatalf("ride = %+v, want %s/pending", gotRide, ride)
	}
	if stops == nil {
		t.Errorf("stops = null in %s, want an empty array", raw)
	}
}
