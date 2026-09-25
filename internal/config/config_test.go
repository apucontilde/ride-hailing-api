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
