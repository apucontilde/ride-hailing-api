package config

import (
	"math"
	"testing"
)

// Plan 06 knobs: the per-region graph budget and the per-city datasource pools.
// Load() is exercised through the real environment, so these cases are exactly
// what an operator's `ROUTING_*` variables do in production.
func TestRoutingDatasourceConfigFromEnv(t *testing.T) {
	cases := []struct {
		name      string
		env       map[string]string
		wantMax   int
		wantSSL   string
		wantConns int
	}{
		{
			name:      "defaults",
			wantMax:   0, // 0 = keep every region's graph
			wantSSL:   "disable",
			wantConns: 10,
		},
		{
			name:      "max_regions_set",
			env:       map[string]string{"ROUTING_MAX_REGIONS_IN_MEMORY": "2"},
			wantMax:   2,
			wantSSL:   "disable",
			wantConns: 10,
		},
		{
			name:      "max_regions_garbage_falls_back",
			env:       map[string]string{"ROUTING_MAX_REGIONS_IN_MEMORY": "many"},
			wantMax:   0,
			wantSSL:   "disable",
			wantConns: 10,
		},
		{
			// Negative is passed through; the repository treats <= 0 as
			// "no budget, never evict", so it must not become a panic.
			name:      "max_regions_negative_is_unlimited",
			env:       map[string]string{"ROUTING_MAX_REGIONS_IN_MEMORY": "-1"},
			wantMax:   -1,
			wantSSL:   "disable",
			wantConns: 10,
		},
		{
			name:      "datasource_sslmode_inherits_local_db",
			env:       map[string]string{"DB_SSLMODE": "require"},
			wantMax:   0,
			wantSSL:   "require",
			wantConns: 10,
		},
		{
			name:      "datasource_sslmode_overrides_local_db",
			env:       map[string]string{"DB_SSLMODE": "require", "ROUTING_DATASOURCE_SSLMODE": "verify-full"},
			wantMax:   0,
			wantSSL:   "verify-full",
			wantConns: 10,
		},
		{
			name:      "datasource_max_conns",
			env:       map[string]string{"ROUTING_DATASOURCE_MAX_CONNS": "4"},
			wantMax:   0,
			wantSSL:   "disable",
			wantConns: 4,
		},
		{
			name:      "datasource_max_conns_garbage_falls_back",
			env:       map[string]string{"ROUTING_DATASOURCE_MAX_CONNS": "lots"},
			wantMax:   0,
			wantSSL:   "disable",
			wantConns: 10,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Normalize the ambient environment first, then apply the case.
			for _, k := range []string{
				"DB_SSLMODE", "ROUTING_DATASOURCE_SSLMODE", "ROUTING_DATASOURCE_MAX_CONNS",
				"ROUTING_MAX_REGIONS_IN_MEMORY",
			} {
				t.Setenv(k, "")
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			cfg := Load()
			if cfg.RoutingMaxRegionsInMemory != tc.wantMax {
				t.Errorf("RoutingMaxRegionsInMemory = %d, want %d", cfg.RoutingMaxRegionsInMemory, tc.wantMax)
			}
			if cfg.RoutingDatasourceSSLMode != tc.wantSSL {
				t.Errorf("RoutingDatasourceSSLMode = %q, want %q", cfg.RoutingDatasourceSSLMode, tc.wantSSL)
			}
			if cfg.RoutingDatasourceMaxConns != tc.wantConns {
				t.Errorf("RoutingDatasourceMaxConns = %d, want %d", cfg.RoutingDatasourceMaxConns, tc.wantConns)
			}
		})
	}
}

// ROUTING_SNAP_RADIUS_M (api_plans [routing]_estimate_fallback_default, bug #2):
// the default must be FINITE, or the no-coverage check never runs and every pin
// however remote snaps to the nearest road — which is what made the honest
// is_estimate answer unreachable in the shipped configuration. 0 remains a
// supported always-snap opt-in, and an unparseable value falls back to the
// default (never to 0, which would silently re-open the bug).
func TestRoutingSnapRadiusConfigFromEnv(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want float64
	}{
		{
			name: "default_is_finite",
			want: 50000,
		},
		{
			name: "explicit_zero_is_always_snap_opt_in",
			env:  map[string]string{"ROUTING_SNAP_RADIUS_M": "0"},
			want: 0,
		},
		{
			name: "explicit_radius",
			env:  map[string]string{"ROUTING_SNAP_RADIUS_M": "250"},
			want: 250,
		},
		{
			// A typo must NOT degrade to "always snap", which is the exact
			// behavior bug #2 removed.
			name: "garbage_falls_back_to_default_not_zero",
			env:  map[string]string{"ROUTING_SNAP_RADIUS_M": "far"},
			want: 50000,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("ROUTING_SNAP_RADIUS_M", "")
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			if got := Load().RoutingSnapRadiusM; got != tc.want {
				t.Errorf("RoutingSnapRadiusM = %v, want %v", got, tc.want)
			}
		})
	}
}

// ROUTING_ENGINE (api_plans [routing]_native_engine_default, bug #1): `native`
// is the intentional PERMANENT default — the benchmark gate that once left the
// choice "pending" is closed. This test pins it so a future edit cannot quietly
// reopen the decision by flipping the default, and so the whitelist's failure
// direction stays pinned too: a typo must degrade to the FASTER engine.
func TestRoutingEngineDefaultIsNative(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want string
	}{
		{
			name: "unset_defaults_to_native",
			want: "native",
		},
		{
			name: "explicit_native",
			env:  map[string]string{"ROUTING_ENGINE": "native"},
			want: "native",
		},
		{
			// The opt-in stays supported, for parity/validation work.
			name: "explicit_pgrouting",
			env:  map[string]string{"ROUTING_ENGINE": "pgrouting"},
			want: "pgrouting",
		},
		{
			// A typo must not select an engine nobody asked for.
			name: "typo_falls_back_to_native",
			env:  map[string]string{"ROUTING_ENGINE": "pgroutng"},
			want: "native",
		},
		{
			name: "case_mismatch_falls_back_to_native",
			env:  map[string]string{"ROUTING_ENGINE": "Native"},
			want: "native",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("ROUTING_ENGINE", "")
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			if got := Load().RoutingEngine; got != tc.want {
				t.Errorf("RoutingEngine = %q, want %q", got, tc.want)
			}
		})
	}
}

// Elevation knobs (api_plans/[elevation]): ON by default for the native engine
// at the measured operating point (AscentW 12, the calibrated DeadbandM 3.8),
// and the bool whitelist fails CLOSED (a typo means off, never on).
func TestRoutingElevationConfigFromEnv(t *testing.T) {
	cases := []struct {
		name         string
		env          map[string]string
		wantEnabled  bool
		wantAscent   float64
		wantDescent  float64
		wantMaxGrade float64
		wantDeadband float64
		wantMinCover float64
	}{
		// Unset/empty means ON now (the flip); the weights are the measured
		// ship point.
		{name: "defaults_on", wantEnabled: true, wantAscent: 12, wantDescent: 0.3, wantMaxGrade: 0.15, wantDeadband: 3.8, wantMinCover: 0.99},
		{
			name:         "on",
			env:          map[string]string{"ROUTING_ELEVATION": "on"},
			wantEnabled:  true,
			wantAscent:   12,
			wantDescent:  0.3,
			wantMaxGrade: 0.15,
			wantDeadband: 3.8,
			wantMinCover: 0.99,
		},
		{
			name: "weights_set",
			env: map[string]string{
				"ROUTING_ELEVATION":         "on",
				"ROUTING_ASCENT_WEIGHT":     "2",
				"ROUTING_DESCENT_WEIGHT":    "0.4",
				"ROUTING_MAX_GRADE":         "0.25",
				"ROUTING_ELEV_DEADBAND_M":   "5",
				"ROUTING_ELEV_MIN_COVERAGE": "0.9",
			},
			wantEnabled:  true,
			wantAscent:   2,
			wantDescent:  0.4,
			wantMaxGrade: 0.25,
			wantDeadband: 5,
			wantMinCover: 0.9,
		},
		{
			// A typo must fail CLOSED (off), like ROUTING_ENGINE's whitelist.
			name:         "typo_fails_closed",
			env:          map[string]string{"ROUTING_ELEVATION": "maybe"},
			wantEnabled:  false,
			wantAscent:   12,
			wantDescent:  0.3,
			wantMaxGrade: 0.15,
			wantDeadband: 3.8,
			wantMinCover: 0.99,
		},
		{
			// "off" explicitly stays off even with other knobs set.
			name:         "explicit_off",
			env:          map[string]string{"ROUTING_ELEVATION": "off", "ROUTING_ASCENT_WEIGHT": "9"},
			wantAscent:   9,
			wantDescent:  0.3,
			wantMaxGrade: 0.15,
			wantDeadband: 3.8,
			wantMinCover: 0.99,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{
				"ROUTING_ELEVATION", "ROUTING_ASCENT_WEIGHT", "ROUTING_DESCENT_WEIGHT",
				"ROUTING_MAX_GRADE", "ROUTING_ELEV_DEADBAND_M", "ROUTING_ELEV_MIN_COVERAGE",
			} {
				t.Setenv(k, "")
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			e := Load().RoutingElevation
			if e.Enabled != tc.wantEnabled {
				t.Errorf("Enabled = %v, want %v", e.Enabled, tc.wantEnabled)
			}
			if e.AscentWeight != tc.wantAscent {
				t.Errorf("AscentWeight = %v, want %v", e.AscentWeight, tc.wantAscent)
			}
			if e.DescentWeight != tc.wantDescent {
				t.Errorf("DescentWeight = %v, want %v", e.DescentWeight, tc.wantDescent)
			}
			if e.MaxGrade != tc.wantMaxGrade {
				t.Errorf("MaxGrade = %v, want %v", e.MaxGrade, tc.wantMaxGrade)
			}
			if e.DeadbandM != tc.wantDeadband {
				t.Errorf("DeadbandM = %v, want %v", e.DeadbandM, tc.wantDeadband)
			}
			if e.MinCoverage != tc.wantMinCover {
				t.Errorf("MinCoverage = %v, want %v", e.MinCoverage, tc.wantMinCover)
			}
		})
	}
}

// Bug #24 ([routing]_gate_correctness.md §A5): the elevation coverage gate is
// ONE shared constant — DefaultElevationMinCoverage — used by BOTH the ingest
// gate (elevtool's -min-coverage default imports it; cmd/elevtool pins that
// half in TestMinCoverageFlagDefaultIsTheSharedConfigConstant) and the runtime
// gate (ROUTING_ELEV_MIN_COVERAGE's default, wired in Load). The two used to
// drift (ingest 0.98 vs runtime 0.99), so a region that passed ingest silently
// degraded to FLAT routing at runtime. These cases pin the value, the wiring,
// and that an operator override still wins.
func TestElevationMinCoverageIsOneSharedIngestRuntimeGate(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want float64
	}{
		{
			// The runtime default must BE the shared constant, not a copy of
			// its value: this is the wiring half of the regression pin.
			name: "runtime_default_is_the_shared_constant",
			want: DefaultElevationMinCoverage,
		},
		{
			// And the shared constant's value is the measured gate (100.00%
			// coverage on the SJ import), not something a rename can reset.
			name: "shared_constant_is_0.99",
			want: 0.99,
		},
		{
			name: "env_override_still_wins",
			env:  map[string]string{"ROUTING_ELEV_MIN_COVERAGE": "0.95"},
			want: 0.95,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("ROUTING_ELEV_MIN_COVERAGE", "")
			for k, v := range tc.env {
				t.Setenv(k, v)
			}
			if got := Load().RoutingElevation.MinCoverage; got != tc.want {
				t.Errorf("RoutingElevation.MinCoverage = %v, want %v", got, tc.want)
			}
		})
	}
}

// Fare knobs (api_plans/STATUS.md [fare]): FARE_CURRENCY is the
// deployment-wide expected currency (default USD) and FARE_MAX_MULTIPLIER the
// cap on the unified conditions multiplier (default 3.0). Both go through
// getEnv/getFloat, so they fall back to their documented defaults when unset or
// unparseable, and there is NO currency validation: an unknown code is accepted
// verbatim. This test pins that real behaviour rather than inventing a currency
// whitelist the code does not have.
func TestFareConfigFromEnv(t *testing.T) {
	cases := []struct {
		name           string
		env            map[string]string
		wantCurrency   string
		wantMultiplier float64
	}{
		{
			name:           "defaults",
			wantCurrency:   "USD",
			wantMultiplier: 3.0,
		},
		{
			name:           "explicit_override",
			env:            map[string]string{"FARE_CURRENCY": "eur", "FARE_MAX_MULTIPLIER": "2.5"},
			wantCurrency:   "eur",
			wantMultiplier: 2.5,
		},
		{
			// A garbage multiplier must fall back to the default cap, never
			// to 0 (which the service treats as "use the default" anyway, but
			// pinning the config value is what keeps that honest).
			name:           "garbage_multiplier_falls_back_to_default",
			env:            map[string]string{"FARE_MAX_MULTIPLIER": "triple"},
			wantCurrency:   "USD",
			wantMultiplier: 3.0,
		},
		{
			// getEnv has no whitelist, so a garbage currency is accepted
			// verbatim — the name says so explicitly so nobody reads this as
			// validation that does not exist.
			name:           "garbage_currency_is_accepted_verbatim_no_validation",
			env:            map[string]string{"FARE_CURRENCY": "not-a-currency"},
			wantCurrency:   "not-a-currency",
			wantMultiplier: 3.0,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{"FARE_CURRENCY", "FARE_MAX_MULTIPLIER"} {
				t.Setenv(k, "")
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			cfg := Load()
			if cfg.FareCurrency != tc.wantCurrency {
				t.Errorf("FareCurrency = %q, want %q", cfg.FareCurrency, tc.wantCurrency)
			}
			if cfg.FareMaxMultiplier != tc.wantMultiplier {
				t.Errorf("FareMaxMultiplier = %v, want %v", cfg.FareMaxMultiplier, tc.wantMultiplier)
			}
		})
	}
}

// RIDE_MAX_STOPS (api_plans/[fare]_waypoint_fare.md §5) is the shared itinerary
// cap. Load pins the default (8) and the env override; the non-positive
// fallback lives at the consumer (BuildItinerary), so Load passes a negative
// through verbatim.
func TestRideMaxStopsConfigFromEnv(t *testing.T) {
	cases := []struct {
		name string
		env  map[string]string
		want int
	}{
		{name: "default_is_eight", want: DefaultRideMaxStops},
		{name: "explicit_override", env: map[string]string{"RIDE_MAX_STOPS": "3"}, want: 3},
		{
			// getInt falls back to the default on an unparseable value; the
			// non-positive fallback is applied by the consumer, not here, so
			// even a negative is passed through.
			name: "garbage_falls_back_to_default",
			env:  map[string]string{"RIDE_MAX_STOPS": "many"},
			want: DefaultRideMaxStops,
		},
		{name: "negative_is_passed_through_for_the_consumer", env: map[string]string{"RIDE_MAX_STOPS": "-1"}, want: -1},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("RIDE_MAX_STOPS", "")
			if tc.env != nil {
				t.Setenv("RIDE_MAX_STOPS", tc.env["RIDE_MAX_STOPS"])
			}
			if got := Load().RideMaxStops; got != tc.want {
				t.Errorf("RideMaxStops = %d, want %d", got, tc.want)
			}
		})
	}
	if DefaultRideMaxStops != 8 {
		t.Errorf("DefaultRideMaxStops = %d, want the documented 8", DefaultRideMaxStops)
	}
}

// Proximity arrival geofence knobs
// (api_plans/[arrival]_proximity_arrival_geofence.md §2.2): ON by default with
// the 300/80/30/10 product thresholds, the bool whitelist fails CLOSED (a typo
// means off, never on), and an unparseable float falls back to the documented
// default rather than to 0 (which would silently disable a leg).
func TestGeofenceConfigFromEnv(t *testing.T) {
	cases := []struct {
		name       string
		env        map[string]string
		wantOn     bool
		wantNearby float64
		wantArrive float64
		wantHyst   float64
		wantMinMov float64
	}{
		{
			name:       "defaults_on",
			wantOn:     true,
			wantNearby: 300,
			wantArrive: 80,
			wantHyst:   30,
			wantMinMov: 10,
		},
		{
			name:       "explicit_on",
			env:        map[string]string{"GEOFENCE_ENABLED": "on"},
			wantOn:     true,
			wantNearby: 300,
			wantArrive: 80,
			wantHyst:   30,
			wantMinMov: 10,
		},
		{
			name:       "explicit_off",
			env:        map[string]string{"GEOFENCE_ENABLED": "off"},
			wantOn:     false,
			wantNearby: 300,
			wantArrive: 80,
			wantHyst:   30,
			wantMinMov: 10,
		},
		{
			// A typo must fail CLOSED (off), never open.
			name:       "typo_fails_closed",
			env:        map[string]string{"GEOFENCE_ENABLED": "maybe"},
			wantOn:     false,
			wantNearby: 300,
			wantArrive: 80,
			wantHyst:   30,
			wantMinMov: 10,
		},
		{
			name: "radii_override",
			env: map[string]string{
				"GEOFENCE_NEARBY_RADIUS_M": "500",
				"GEOFENCE_ARRIVE_RADIUS_M": "120",
				"GEOFENCE_HYSTERESIS_M":    "45",
				"GEOFENCE_MIN_MOVE_M":      "5",
			},
			wantOn:     true,
			wantNearby: 500,
			wantArrive: 120,
			wantHyst:   45,
			wantMinMov: 5,
		},
		{
			// Garbage falls back to the documented default, never to 0.
			name: "garbage_radius_falls_back_to_default",
			env: map[string]string{
				"GEOFENCE_NEARBY_RADIUS_M": "close",
				"GEOFENCE_ARRIVE_RADIUS_M": "at the kerb",
			},
			wantOn:     true,
			wantNearby: 300,
			wantArrive: 80,
			wantHyst:   30,
			wantMinMov: 10,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{
				"GEOFENCE_ENABLED", "GEOFENCE_NEARBY_RADIUS_M", "GEOFENCE_ARRIVE_RADIUS_M",
				"GEOFENCE_HYSTERESIS_M", "GEOFENCE_MIN_MOVE_M",
			} {
				t.Setenv(k, "")
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			a := Load().Arrival
			if a.Enabled != tc.wantOn {
				t.Errorf("Enabled = %v, want %v", a.Enabled, tc.wantOn)
			}
			if a.NearbyRadiusM != tc.wantNearby {
				t.Errorf("NearbyRadiusM = %v, want %v", a.NearbyRadiusM, tc.wantNearby)
			}
			if a.ArriveRadiusM != tc.wantArrive {
				t.Errorf("ArriveRadiusM = %v, want %v", a.ArriveRadiusM, tc.wantArrive)
			}
			if a.HysteresisM != tc.wantHyst {
				t.Errorf("HysteresisM = %v, want %v", a.HysteresisM, tc.wantHyst)
			}
			if a.MinMoveM != tc.wantMinMov {
				t.Errorf("MinMoveM = %v, want %v", a.MinMoveM, tc.wantMinMov)
			}
		})
	}
}

// Payout knobs (api_plans/[payout]_driver_earnings_and_withdraw.md): the
// withdrawal floor, the ledger currency and the platform commission.
// MinWithdrawCents and Currency fall back to their documented defaults through
// getInt/getEnv; the commission parser is the load-bearing one — it FAILS
// CLOSED to 0 (no cut) for unset, empty, garbage, non-finite (NaN/±Inf) or
// out-of-range input.
//
// The NaN/±Inf cases are the regression pin for the finding-2 fix:
// strconv.ParseFloat("NaN") returns (NaN, nil) — no error — and both range
// comparisons are false for NaN, so a naive `f < 0 || f > 1` check would let a
// non-finite rate through. That rate would then make every completion credit
// int64(math.Round(fare*(1-NaN)*100)) = min-int64, which is <= 0, so the ride
// service would silently credit NOTHING. A finite in-range value is passed
// through unchanged; the boundaries 0 and 1 are valid cuts.
func TestPayoutConfigFromEnv(t *testing.T) {
	cases := []struct {
		name           string
		env            map[string]string
		wantMin        int64
		wantCurrency   string
		wantCommission float64
	}{
		{
			name:           "unset_defaults",
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: DefaultPayoutCommissionRate,
		},
		{
			name: "valid_values",
			env: map[string]string{
				"PAYOUT_MIN_WITHDRAW_CENTS": "1000",
				"PAYOUT_CURRENCY":           "eur",
				"PAYOUT_COMMISSION_RATE":    "0.15",
			},
			wantMin:        1000,
			wantCurrency:   "eur",
			wantCommission: 0.15,
		},
		{
			name:           "empty_commission_is_default",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": ""},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: DefaultPayoutCommissionRate,
		},
		{
			// The regression pin: NaN parses without error and is neither
			// < 0 nor > 1, so only the IsNaN guard catches it.
			name:           "nan_fails_closed",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "NaN"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			name:           "positive_inf_fails_closed",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "+Inf"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			name:           "negative_inf_fails_closed",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "-Inf"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			name:           "negative_fails_closed",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "-0.1"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			name:           "above_one_fails_closed",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "1.5"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			name:           "garbage_fails_closed",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "half"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			// 1 is the maximum valid cut (the driver is credited nothing).
			name:           "one_is_accepted_boundary",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "1"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 1,
		},
		{
			name:           "zero_is_accepted_and_equals_default",
			env:            map[string]string{"PAYOUT_COMMISSION_RATE": "0"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			name:           "garbage_min_falls_back",
			env:            map[string]string{"PAYOUT_MIN_WITHDRAW_CENTS": "lots"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   DefaultPayoutCurrency,
			wantCommission: 0,
		},
		{
			// getEnv has no whitelist, so a garbage currency is accepted
			// verbatim — named so nobody reads this as validation that does
			// not exist.
			name:           "garbage_currency_is_accepted_verbatim_no_validation",
			env:            map[string]string{"PAYOUT_CURRENCY": "not-a-currency"},
			wantMin:        DefaultPayoutMinWithdrawCents,
			wantCurrency:   "not-a-currency",
			wantCommission: 0,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{
				"PAYOUT_MIN_WITHDRAW_CENTS", "PAYOUT_CURRENCY", "PAYOUT_COMMISSION_RATE",
			} {
				t.Setenv(k, "")
			}
			for k, v := range tc.env {
				t.Setenv(k, v)
			}

			p := Load().Payout
			if p.MinWithdrawCents != tc.wantMin {
				t.Errorf("MinWithdrawCents = %d, want %d", p.MinWithdrawCents, tc.wantMin)
			}
			if p.Currency != tc.wantCurrency {
				t.Errorf("Currency = %q, want %q", p.Currency, tc.wantCurrency)
			}
			if p.CommissionRate != tc.wantCommission {
				t.Errorf("CommissionRate = %v, want %v", p.CommissionRate, tc.wantCommission)
			}
			// NaN never equals itself, so the equality check above cannot be
			// trusted alone: assert finiteness explicitly. The parser must
			// never hand the ride service a non-finite cut.
			if math.IsNaN(p.CommissionRate) || math.IsInf(p.CommissionRate, 0) {
				t.Errorf("CommissionRate = %v is non-finite; the parser must fail closed to %v",
					p.CommissionRate, DefaultPayoutCommissionRate)
			}
		})
	}
}
