package config

import "testing"

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

// Elevation knobs (api_plans/[elevation]): off by default; the numeric default
// weights are proposals, and the bool whitelist fails CLOSED (a typo means off,
// never on).
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
		{name: "defaults_off", wantAscent: 1.5, wantDescent: 0.3, wantMaxGrade: 0.15, wantDeadband: 3.0, wantMinCover: 0.99},
		{
			name:         "on",
			env:          map[string]string{"ROUTING_ELEVATION": "on"},
			wantEnabled:  true,
			wantAscent:   1.5,
			wantDescent:  0.3,
			wantMaxGrade: 0.15,
			wantDeadband: 3.0,
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
			wantAscent:   1.5,
			wantDescent:  0.3,
			wantMaxGrade: 0.15,
			wantDeadband: 3.0,
			wantMinCover: 0.99,
		},
		{
			// "off" explicitly stays off even with other knobs set.
			name:         "explicit_off",
			env:          map[string]string{"ROUTING_ELEVATION": "off", "ROUTING_ASCENT_WEIGHT": "9"},
			wantAscent:   9,
			wantDescent:  0.3,
			wantMaxGrade: 0.15,
			wantDeadband: 3.0,
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
