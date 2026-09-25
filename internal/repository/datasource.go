package repository

import (
	"errors"
	"fmt"
	"log"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq" // the driver the per-datasource pools below open with

	"ride-hailing-api/internal/config"
)

// ErrDatasourceUnavailable marks a routing failure caused by ANOTHER city's
// database being absent, unopenable or broken (api_plans/06). It is the
// fail-safe seam: the service turns it into a straight-line estimate (HTTP 200,
// is_estimate) instead of a 500, so one city being down never fails a request
// that another city could answer. Local-database failures are NOT tagged with
// it — those stay hard errors, because a stack whose own database is gone has a
// real problem worth surfacing.
var ErrDatasourceUnavailable = errors.New("routing datasource unavailable")

const (
	// datasourceConnectTimeout bounds a single dial to a city database. It is
	// what keeps one unreachable datasource from stalling a request: a TCP
	// connect either refuses instantly or gives up here.
	datasourceConnectTimeout = 5 * time.Second
	// datasourceRetryDelay is how long a failed open is remembered before the
	// next request retries. Resolution failures are cached rather than retried
	// per request so a down city costs one dial per window, not one per pin.
	datasourceRetryDelay = 30 * time.Second
)

// DatasourceRef is one routing_datasources row (api_plans/04): where a city's
// road network lives. There is deliberately NO password field — the row is
// world-readable to anyone with DB access, the secret comes from the
// environment (see DatasourcePasswordEnv).
type DatasourceRef struct {
	DatasourceID string
	Host         string
	Port         int
	DBName       string
	DBUser       string
	Label        string
}

// datasourcesSQL reads ONE row by id. Password is not a column and must never
// become one; the id is a bound parameter.
const datasourcesSQL = `
SELECT datasource_id,
       host,
       port,
       dbname,
       db_user,
       COALESCE(label, '') AS label
FROM routing_datasources
WHERE datasource_id = $1`

// DatasourcePasswordEnv is the environment variable that carries a datasource's
// password: DATASOURCE_<ID>_PASSWORD, the id uppercased with separators folded
// to underscores ("cr-lc" -> DATASOURCE_CR_LC_PASSWORD). Passwords are never
// stored in routing_datasources, so this or ~/.pgpass is the only source.
func DatasourcePasswordEnv(datasourceID string) string {
	return "DATASOURCE_" + datasourceEnvKey(datasourceID) + "_PASSWORD"
}

func datasourceEnvKey(datasourceID string) string {
	return strings.ToUpper(strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		default:
			return '_'
		}
	}, datasourceID))
}

// DatasourceDSN builds the libpq connection string for one datasource row.
//
// The password is included ONLY when DATASOURCE_<ID>_PASSWORD is set: an empty
// password parameter would suppress lib/pq's own ~/.pgpass (and PGPASSWORD)
// lookup, which is the other supported way to authenticate. connect_timeout
// bounds the dial so an unreachable city fails fast instead of hanging a
// request.
func DatasourceDSN(ref DatasourceRef, sslMode string) string {
	host := ref.Host
	if host == "" {
		host = "localhost"
	}
	port := ref.Port
	if port <= 0 {
		port = 5432
	}
	if sslMode == "" {
		sslMode = "disable"
	}

	u := &url.URL{
		Scheme: "postgres",
		Host:   net.JoinHostPort(host, strconv.Itoa(port)),
		Path:   "/" + ref.DBName,
	}
	if ref.DBUser != "" {
		if pw := os.Getenv(DatasourcePasswordEnv(ref.DatasourceID)); pw != "" {
			u.User = url.UserPassword(ref.DBUser, pw)
		} else {
			u.User = url.User(ref.DBUser)
		}
	}
	q := u.Query()
	q.Set("sslmode", sslMode)
	q.Set("connect_timeout", strconv.Itoa(int(datasourceConnectTimeout/time.Second)))
	u.RawQuery = q.Encode()
	return u.String()
}

// DatasourcePools resolves a routing_datasources id to its own *sqlx.DB and
// caches it — one pool per city database, so each city's connections, load and
// failures are its own (api_plans/06, the near deployment shape).
//
// Resolution is lazy in two layers: nothing is opened until a region's registry
// row actually names a datasource, and the row itself is read from the LOCAL
// pool on first use. Boot therefore never touches a remote database and an
// operator can add a city by inserting a row.
//
// Every failure mode — no local handle, missing table, unknown id, unreadable
// row, unreachable host — resolves to a nil pool, which the repos read as "this
// datasource covers nothing". That is what makes one city being down a local
// event: its regions degrade to estimates, every other region keeps routing.
type DatasourcePools struct {
	local    *sqlx.DB
	sslMode  string
	maxConns int

	mu     sync.Mutex
	pools  map[string]*sqlx.DB
	failed map[string]time.Time
}

// NewDatasourcePools builds the pool registry over the local handle. maxConns
// <= 0 leaves each pool's sizing to database/sql. A nil local handle is legal
// (it only makes every remote resolution fail, which is the fail-safe answer).
func NewDatasourcePools(local *sqlx.DB, sslMode string, maxConns int) *DatasourcePools {
	return &DatasourcePools{
		local:    local,
		sslMode:  sslMode,
		maxConns: maxConns,
		pools:    make(map[string]*sqlx.DB),
		failed:   make(map[string]time.Time),
	}
}

// NewDatasourcePoolsFromConfig is the wiring entrypoint (internal/router): the
// local database and the server config, nothing else.
func NewDatasourcePoolsFromConfig(local *sqlx.DB, cfg *config.Config) *DatasourcePools {
	if cfg == nil {
		return NewDatasourcePools(local, "", 0)
	}
	return NewDatasourcePools(local, cfg.RoutingDatasourceSSLMode, cfg.RoutingDatasourceMaxConns)
}

// Pool returns the pool that owns datasourceID's rows, or nil when that
// datasource cannot be served. "" is the LOCAL pool, which is always available
// even when the registry itself is not.
func (p *DatasourcePools) Pool(datasourceID string) *sqlx.DB {
	if p == nil {
		return nil
	}
	if datasourceID == "" {
		return p.local
	}

	p.mu.Lock()
	if db, ok := p.pools[datasourceID]; ok {
		p.mu.Unlock()
		return db
	}
	if failedAt, ok := p.failed[datasourceID]; ok && time.Since(failedAt) < datasourceRetryDelay {
		p.mu.Unlock()
		return nil
	}
	p.mu.Unlock()

	db, err := p.open(datasourceID)
	if err != nil {
		log.Printf("[routing] datasource %q unavailable, its regions fall back to estimates: %v", datasourceID, err)
		p.markFailed(datasourceID)
		return nil
	}

	p.mu.Lock()
	if existing, ok := p.pools[datasourceID]; ok {
		// Another request won the race; one pool per id, always.
		p.mu.Unlock()
		_ = db.Close()
		return existing
	}
	p.pools[datasourceID] = db
	delete(p.failed, datasourceID)
	p.mu.Unlock()
	return db
}

// open reads the row from the LOCAL registry and dials it. It never returns a
// usable pool for a datasource it could not fully resolve.
func (p *DatasourcePools) open(datasourceID string) (*sqlx.DB, error) {
	if p.local == nil {
		return nil, errors.New("no local database to read routing_datasources from")
	}

	var row struct {
		DatasourceID string `db:"datasource_id"`
		Host         string `db:"host"`
		Port         int    `db:"port"`
		DBName       string `db:"dbname"`
		DBUser       string `db:"db_user"`
		Label        string `db:"label"`
	}
	if err := p.local.Get(&row, datasourcesSQL, datasourceID); err != nil {
		return nil, fmt.Errorf("datasource %q is not provisioned: %w", datasourceID, err)
	}

	ref := DatasourceRef{
		DatasourceID: row.DatasourceID,
		Host:         row.Host,
		Port:         row.Port,
		DBName:       row.DBName,
		DBUser:       row.DBUser,
		Label:        row.Label,
	}
	db, err := sqlx.Connect("postgres", DatasourceDSN(ref, p.sslMode))
	if err != nil {
		return nil, fmt.Errorf("datasource %q (%s@%s:%d/%s): %w",
			ref.DatasourceID, ref.DBUser, ref.Host, ref.Port, ref.DBName, err)
	}
	if p.maxConns > 0 {
		db.SetMaxOpenConns(p.maxConns)
		if p.maxConns < 2 {
			db.SetMaxIdleConns(p.maxConns)
		}
	}
	return db, nil
}

func (p *DatasourcePools) markFailed(datasourceID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.failed == nil {
		p.failed = make(map[string]time.Time)
	}
	p.failed[datasourceID] = time.Now()
}

// Close releases every opened pool. Nothing in the request path calls it — the
// pools live as long as the process — but tests and graceful shutdown do.
func (p *DatasourcePools) Close() {
	if p == nil {
		return
	}
	p.mu.Lock()
	opened := p.pools
	p.pools = make(map[string]*sqlx.DB)
	p.mu.Unlock()
	for _, db := range opened {
		_ = db.Close()
	}
}

// poolFor is the one place the repos turn a region's datasource into a pool: ""
// is the local handle, anything else resolves through the registry, and a nil
// result means the datasource cannot serve that region (fail-safe: no coverage).
func poolFor(local *sqlx.DB, pools *DatasourcePools, datasource string) *sqlx.DB {
	if datasource == "" {
		return local
	}
	if pools == nil {
		return nil
	}
	return pools.Pool(datasource)
}

// datasourceErr tags a failure that happened against a REMOTE pool so the
// service can degrade it to an estimate. Local failures pass through unchanged.
func datasourceErr(datasource string, err error) error {
	if datasource == "" || err == nil {
		return err
	}
	return fmt.Errorf("%w: %s", ErrDatasourceUnavailable, err)
}

// noPoolErr is the routing-side error for a region whose datasource has no
// usable pool. It carries ErrDatasourceUnavailable so the request degrades to
// an estimate instead of a 500.
func noPoolErr(datasource string) error {
	return fmt.Errorf("%w: datasource %q has no usable pool", ErrDatasourceUnavailable, datasource)
}
