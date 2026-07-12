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
