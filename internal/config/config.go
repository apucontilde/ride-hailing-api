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

	// RoutingEngine selects the shortest-path implementation: "native" (in-process
	// A*, default) or "pgrouting" (pgRouting via the pgr_dijkstra functions).
	// Whitelisted at load; anything else falls back to "native".
	RoutingEngine string
	// RoutingSnapRadiusM is the max distance (meters) a pin may snap to a road
	// vertex to count as covered. <= 0 disables the check (always snap, matching
	// the native engine's behavior).
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
}

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
		RoutingSnapRadiusM:        getFloat("ROUTING_SNAP_RADIUS_M", 0),
		RoutingDefaultRegion:      getEnv("ROUTING_DEFAULT_REGION", ""),
		RoutingMaxRegionsInMemory: getInt("ROUTING_MAX_REGIONS_IN_MEMORY", 0),
		// A city database may live on another host with different TLS
		// requirements, so the mode is its own knob; unset means "same as the
		// local database".
		RoutingDatasourceSSLMode:  getEnv("ROUTING_DATASOURCE_SSLMODE", getEnv("DB_SSLMODE", "disable")),
		RoutingDatasourceMaxConns: getInt("ROUTING_DATASOURCE_MAX_CONNS", 10),
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
// value (including unset) means the native in-process A* engine.
func routingEngineFromEnv() string {
	switch getEnv("ROUTING_ENGINE", "native") {
	case "native", "pgrouting":
		return getEnv("ROUTING_ENGINE", "native")
	default:
		return "native"
	}
}

func getFloat(key string, fallback float64) float64 {
	if v := os.Getenv(key); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return fallback
}
