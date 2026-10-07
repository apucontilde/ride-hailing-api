package config

import (
	"os"
	"strconv"
	"time"
)

type Config struct {
	ServerPort string

	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
	DBSSLMode  string

	RedisHost string
	RedisPort string

	JWTSecret     string
	JWTAccessTTL  time.Duration
	JWTRefreshTTL time.Duration

	RateLimitLogin    int
	RateLimitRegister int
	RateLimitRide     int
	RateLimitGeneral  int
	RateLimitWindow   time.Duration

	DEMFilePath  string
	DebugLogging bool

	PlacesSeedOnStart  bool
	PlacesGeoJSONPath  string
	PlacesMaxRadiusM   float64
	PlacesDefaultLimit int

	// RoutingEngine selects the shortest-path implementation: "native" (the
	// in-process A* engine) or "pgrouting" (pgRouting via pgr_dijkstra).
	// Whitelisted at load; anything else falls back to "native", the
	// INTENDED PERMANENT default — the plan-03 benchmark gate is closed, not
	// pending, and a typo therefore degrades to the FASTER engine. Numbers:
	// api_plans/STATUS.md ([routing] decisions). `pgrouting` stays supported
	// for engine-parity/validation work and as the fallback target the factory
	// falls back TO when the extension is missing.
	RoutingEngine string
	// RoutingSnapRadiusM is the max distance (meters) a pin may snap to a road
	// vertex to count as covered; beyond it the route endpoints answer 200 +
	// is_estimate instead of snapping to a road tens of km away. A non-positive
	// value is the documented "always snap" opt-in. Default and rationale:
	// defaultRoutingSnapRadiusM below.
	RoutingSnapRadiusM float64
	// RoutingDefaultRegion names the routing_regions row the resolver falls
	// back to when no candidate region covers a pin. "" (default) relies on the
	// registry's own default_region = TRUE row (api_plans/05).
	RoutingDefaultRegion string
	// RoutingMaxRegionsInMemory caps how many per-region native graphs a pod
	// keeps cached (api_plans/06). 0 (default) keeps every city's graph, which
	// is right for a handful of cities at ~150-200 MB each; a positive N evicts
	// the least-recently-used region graph once N are held, so a pod can run
	// with a deliberate subset.
	RoutingMaxRegionsInMemory int
	// RoutingDatasourceSSLMode is the sslmode used for per-datasource pools
	// (api_plans/06). Empty falls back to the local DB_SSLMODE.
	RoutingDatasourceSSLMode string
	// RoutingDatasourceMaxConns caps each per-datasource pool (api_plans/06).
	// Remote pools serve region snaps (and pgRouting routes when that engine is
	// selected), never the native in-memory hot path, so a small pool per city
	// is the right shape. <= 0 leaves sizing to database/sql.
	RoutingDatasourceMaxConns int

	// RoutingElevation configures the native engine's elevation cost model
	// (api_plans/[elevation]). ON by default for the native engine at the
	// measured operating point (see RoutingElevation). A region with no (or
	// below-MinCoverage) elevation data still degrades to flat, so an install
	// that never ran the elevation backfill reproduces the pre-elevation engine
	// exactly.
	RoutingElevation RoutingElevation

	// FareCurrency is the deployment-wide expected pricing currency
	// (api_plans/STATUS.md [fare]). It defaults to USD and must
	// equal both fare_regions.currency and the active card's currency for every
	// priced region. A mismatch is a typed configuration error — never a silent
	// conversion and never a fallback to another region's card.
	FareCurrency string
	// FareMaxMultiplier caps the unified conditions multiplier (demand ×
	// supply), which is also floored at 1.0 so pricing never discounts below
	// the authored tariff. Default and rationale: DefaultFareMaxMultiplier.
	FareMaxMultiplier float64
}

// Fare defaults (api_plans/STATUS.md [fare]). USD is the
// documented default currency; the cap is tunable without a redeploy so the
// rider never sees an uncapped multiplier.
const (
	DefaultFareCurrency      = "USD"
	DefaultFareMaxMultiplier = 3.0
)

// defaultRoutingSnapRadiusM is ROUTING_SNAP_RADIUS_M's shipped default: 50 km
// (meters), the same scale as PLACES_MAX_RADIUS_M, and the single place the
// rationale lives (the RoutingSnapRadiusM field points here).
//
// It is far larger than any realistic urban pickup-to-road distance (meters to
// a few km) so ordinary pins are unaffected, while still being smaller than the
// default region's own width (~110 km, scripts/import-road-network.sh) so a pin
// in unserved country degrades to a labelled estimate instead of snapping to a
// vertex tens of kilometers away. api_plans
// [routing]_estimate_fallback_default closed bug #2 by making the is_estimate
// path reachable in the DEFAULT configuration: with the previous default of 0
// the coverage check never ran, so every pin however remote resolved to the
// nearest road.
const defaultRoutingSnapRadiusM = 50000

// RoutingElevation configures the native engine's elevation cost model
// (api_plans/[elevation]). ON by default for the native engine at the measured
// operating point below (flipped by the now-condensed deadband-calibrate-and-flip
// execution plan, Stage 3). This is a product decision with a recorded accepted risk — G1
// flat-invariance is uncertified on this import (no <=15 m control box exists,
// best is 33 m relief); it is not a clean eight-of-eight gate. Every numeric
// default carries its measured reason; none is tuned by eye. An install with no
// (or below-MinCoverage) elevation data still degrades to flat, which
// reproduces the pre-elevation engine exactly.
type RoutingElevation struct {
	Enabled       bool    // ROUTING_ELEVATION=on|off; unset/"" = on, garbage = off (fail-closed). Default on.
	AscentWeight  float64 // ROUTING_ASCENT_WEIGHT; default defaultElevationAscentWeight (measured).
	DescentWeight float64 // ROUTING_DESCENT_WEIGHT; default defaultElevationDescentWeight (sweep-held).
	MaxGrade      float64 // ROUTING_MAX_GRADE; default defaultElevationMaxGrade (sweep-held).
	DeadbandM     float64 // ROUTING_ELEV_DEADBAND_M; default 3.8 (calibrated, gate G6).
	MinCoverage   float64 // ROUTING_ELEV_MIN_COVERAGE; default 0.99 (measured 100.00% coverage).
}

// Elevation operating-point defaults — the measured ship point of
// api_plans/[elevation], flipped by the now-condensed deadband-calibrate-and-flip
// execution plan, Stage 3. A default changed without a recorded measured reason is not allowed
// (the calibration plan's own rule), so each carries its evidence.
//
// MEASURED 2026-10-05 by the Stage 2 N=2000 sweep (2,000 routable, 224 rejected
// no-route/no-snap) on the live SJ import, engine native. At AscentW=12 with the
// calibrated DeadbandM=3.8:
//   - median ascent ratio 0.9314 (the old 1.5 default was inert at 1.0000),
//   - 168/2000 pairs qualify for climb avoidance (G2 bar >= 20),
//   - median meters ratio 1.0090 (G3 <= 1.02), p99 1.0901 (G4 <= 1.25),
//   - G7 monotone 1.0000, 1.0000, 0.9976, 0.9769, 0.9314, 0.8940,
//   - real-graph hot path 112.3 ms/op vs 83.9 ms flat = 1.34x (G5 < ~2x).
//
// AscentW=25 is the first point that breaks G3 (median meters 1.0229), so 12 is
// the top of the usable range. DescentW 0.3 and MaxGrade 0.15 are held from the
// sweep (the G7 axis was measured with them; DescentW*MaxGrade = 0.045 < 1, the
// constraint from the head plan). MinCoverage 0.99 guards the measured 100.00%
// coverage (152,665/152,665 vertices, five skadi tiles).
const (
	defaultElevationAscentWeight  = 12
	defaultElevationDescentWeight = 0.3
	defaultElevationMaxGrade      = 0.15
	defaultElevationMinCoverage   = 0.99
)

// defaultElevationDeadbandM is ROUTING_ELEV_DEADBAND_M's measured default — gate
// G6 of api_plans/[elevation]_calibration_and_rollout_gate.md.
//
// MEASURED 2026-10-04 on the live SJ import (152,665 vertices, 100.00 %
// elevation_m covered, five skadi tiles). The estimator is DB-free
// (flatEdgeDeadbandM/flatEdgeAbsDz, internal/repository/elevation_calibration.go);
// the
// measurement run is TestElevationDeadbandCalibration
// (internal/repository/elevation_acceptance_integration_test.go).
//
// Sample set (n = 43,673 edges), "certifiably flat" WITHOUT reading the edge's
// own dz: horizontal length <= 75 m AND both endpoints' 3x3-cell (~330 m) local
// relief <= 15 m. The per-edge |dz| distribution on that set was p50 0.76 m,
// p90 2.82 m, p95 3.80 m, p99 6.47 m, max 14.69 m. The default is the p95
// (3.8 m): it damps the bulk of the DEM's vertical sampling error while staying
// well below real relief, and sits above the data-derived noise floor (the
// same set's median, 0.76 m). Replaces the datasheet provisional 3.0.
const defaultElevationDeadbandM = 3.8

func Load() *Config {
	return &Config{
		ServerPort: getEnv("SERVER_PORT", "8080"),

		DBHost:     getEnv("DB_HOST", "0.0.0.0"),
		DBPort:     getEnv("DB_PORT", "5432"),
		DBUser:     getEnv("DB_USER", "ridehail"),
		DBPassword: getEnv("DB_PASSWORD", "ridehail_pass"),
		DBName:     getEnv("DB_NAME", "ridehailing"),
		DBSSLMode:  getEnv("DB_SSLMODE", "disable"),

		RedisHost: getEnv("REDIS_HOST", "localhost"),
		RedisPort: getEnv("REDIS_PORT", "6379"),

		JWTSecret:     getEnv("JWT_SECRET", "dev-secret-change-in-production"),
		JWTAccessTTL:  getDuration("JWT_ACCESS_TTL", 15*time.Minute),
		JWTRefreshTTL: getDuration("JWT_REFRESH_TTL", 720*time.Hour),

		RateLimitLogin:    getInt("RATE_LIMIT_LOGIN", 20),
		RateLimitRegister: getInt("RATE_LIMIT_REGISTER", 5),
		RateLimitRide:     getInt("RATE_LIMIT_RIDE_CREATE", 10),
		RateLimitGeneral:  getInt("RATE_LIMIT_GENERAL", 100),
		RateLimitWindow:   getDuration("RATE_LIMIT_WINDOW", 60*time.Second),

		DEMFilePath:  getEnv("DEM_FILE_PATH", ""),
		DebugLogging: getEnv("DEBUG_LOGGING", "false") == "true",

		PlacesSeedOnStart:  getEnv("PLACES_SEED_ON_START", "true") == "true",
		PlacesGeoJSONPath:  getEnv("PLACES_GEOJSON_PATH", "data/places.geojson"),
		PlacesMaxRadiusM:   float64(getInt("PLACES_MAX_RADIUS_M", 50000)),
		PlacesDefaultLimit: getInt("PLACES_DEFAULT_LIMIT", 10),

		RoutingEngine:             routingEngineFromEnv(),
		RoutingSnapRadiusM:        getFloat("ROUTING_SNAP_RADIUS_M", defaultRoutingSnapRadiusM),
		RoutingDefaultRegion:      getEnv("ROUTING_DEFAULT_REGION", ""),
		RoutingMaxRegionsInMemory: getInt("ROUTING_MAX_REGIONS_IN_MEMORY", 0),
		// A city database may live on another host with different TLS
		// requirements, so the mode is its own knob; unset means "same as the
		// local database".
		RoutingDatasourceSSLMode:  getEnv("ROUTING_DATASOURCE_SSLMODE", getEnv("DB_SSLMODE", "disable")),
		RoutingDatasourceMaxConns: getInt("ROUTING_DATASOURCE_MAX_CONNS", 10),
		RoutingElevation: RoutingElevation{
			Enabled:       routingElevationEnabledFromEnv(),
			AscentWeight:  getFloat("ROUTING_ASCENT_WEIGHT", defaultElevationAscentWeight),
			DescentWeight: getFloat("ROUTING_DESCENT_WEIGHT", defaultElevationDescentWeight),
			MaxGrade:      getFloat("ROUTING_MAX_GRADE", defaultElevationMaxGrade),
			DeadbandM:     getFloat("ROUTING_ELEV_DEADBAND_M", defaultElevationDeadbandM),
			MinCoverage:   getFloat("ROUTING_ELEV_MIN_COVERAGE", defaultElevationMinCoverage),
		},

		FareCurrency:      getEnv("FARE_CURRENCY", DefaultFareCurrency),
		FareMaxMultiplier: getFloat("FARE_MAX_MULTIPLIER", DefaultFareMaxMultiplier),
	}
}

func (c *Config) DatabaseURL() string {
	return "postgres://" + c.DBUser + ":" + c.DBPassword +
		"@" + c.DBHost + ":" + c.DBPort +
		"/" + c.DBName + "?sslmode=" + c.DBSSLMode
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if i, err := strconv.Atoi(v); err == nil {
			return i
		}
	}
	return fallback
}

func getDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}

// routingEngineFromEnv whitelists ROUTING_ENGINE to native|pgrouting; any other
// value (including unset) means the native in-process A* engine, which is the
// intentional permanent default (see the RoutingEngine field comment and
// api_plans/STATUS.md's [routing] decisions for the benchmark evidence). A
// typo therefore degrades to the FASTER engine, never to the slower one.
func routingEngineFromEnv() string {
	switch getEnv("ROUTING_ENGINE", "native") {
	case "native", "pgrouting":
		return getEnv("ROUTING_ENGINE", "native")
	default:
		return "native"
	}
}

// routingElevationEnabledFromEnv whitelists ROUTING_ELEVATION. Unset or empty
// means ON (the shipped default for the native engine); "on" means on; anything
// else — including a typo — fails CLOSED to off (flat routing), never open.
// os.Getenv is used deliberately in place of getEnv: getEnv collapses unset and
// set-empty into its fallback, so it cannot express "unset -> on" while keeping
// "garbage -> off".
func routingElevationEnabledFromEnv() bool {
	v := os.Getenv("ROUTING_ELEVATION")
	return v == "" || v == "on"
}

func getFloat(key string, fallback float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return fallback
}
