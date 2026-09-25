package repository

import (
	"errors"
	"net/url"
	"strings"
	"testing"

	"github.com/jmoiron/sqlx"
)

// The datasource pool layer is deliberately testable without a database: the
// password convention, the DSN it builds and every fail-safe branch are pure
// functions, and an unreachable registry is exactly the "no coverage" case.

// Passwords are never stored in routing_datasources, so the id-derived env var
// is the only in-band way to carry one.
func TestDatasourcePasswordEnv(t *testing.T) {
	cases := map[string]string{
		"cr-lc":   "DATASOURCE_CR_LC_PASSWORD",
		"d1":      "DATASOURCE_D1_PASSWORD",
		"us-ny-5": "DATASOURCE_US_NY_5_PASSWORD",
		"CR-LC":   "DATASOURCE_CR_LC_PASSWORD",
		// Anything that is not a letter or digit folds to "_" so an operator
		// never has to guess how a datasource id maps to an env name.
		"mx.cdg/1": "DATASOURCE_MX_CDG_1_PASSWORD",
	}
	for id, want := range cases {
		if got := DatasourcePasswordEnv(id); got != want {
			t.Errorf("DatasourcePasswordEnv(%q) = %q, want %q", id, got, want)
		}
	}
}

func TestDatasourceDSN(t *testing.T) {
	base := DatasourceRef{
		DatasourceID: "cr-lc",
		Host:         "city-db.internal",
		Port:         5433,
		DBName:       "routing_lc",
		DBUser:       "routing",
	}

	t.Run("password_from_env", func(t *testing.T) {
		t.Setenv(DatasourcePasswordEnv("cr-lc"), "p@ss:word/1")
		dsn := DatasourceDSN(base, "require")

		u, err := url.Parse(dsn)
		if err != nil {
			t.Fatalf("dsn %q does not parse: %v", dsn, err)
		}
		if u.Scheme != "postgres" || u.Host != "city-db.internal:5433" || u.Path != "/routing_lc" {
			t.Errorf("dsn = %q, want postgres://city-db.internal:5433/routing_lc", dsn)
		}
		pw, _ := u.User.Password()
		if u.User.Username() != "routing" || pw != "p@ss:word/1" {
			t.Errorf("credentials = %q/%q, want routing/p@ss:word/1", u.User.Username(), pw)
		}
		if got := u.Query().Get("sslmode"); got != "require" {
			t.Errorf("sslmode = %q, want require", got)
		}
		// The dial must be bounded or an unreachable city stalls a request.
		if got := u.Query().Get("connect_timeout"); got == "" {
			t.Error("dsn must carry a connect_timeout")
		}
	})

	t.Run("no_password_env_keeps_pgpass_usable", func(t *testing.T) {
		t.Setenv(DatasourcePasswordEnv("cr-lc"), "")
		u, err := url.Parse(DatasourceDSN(base, ""))
		if err != nil {
			t.Fatalf("dsn does not parse: %v", err)
		}
		// lib/pq only falls back to .pgpass / PGPASSWORD when NO password is
		// given, so the parameter must be absent, not empty-but-present.
		if _, hasPw := u.User.Password(); hasPw {
			t.Error("dsn must omit the password when the env var is unset")
		}
		if u.User.Username() != "routing" {
			t.Errorf("user = %q, want routing", u.User.Username())
		}
		if got := u.Query().Get("sslmode"); got != "disable" {
			t.Errorf("sslmode = %q, want the disable default", got)
		}
	})

	t.Run("host_and_port_defaults", func(t *testing.T) {
		u, err := url.Parse(DatasourceDSN(DatasourceRef{DBName: "routing"}, ""))
		if err != nil {
			t.Fatalf("dsn does not parse: %v", err)
		}
		if u.Host != "localhost:5432" {
			t.Errorf("host = %q, want the localhost:5432 default", u.Host)
		}
		if u.User != nil {
			t.Errorf("user = %v, want none when the row has no db_user", u.User)
		}
	})

	t.Run("ipv6_host_is_bracketed", func(t *testing.T) {
		ref := base
		ref.Host = "fd00::1"
		u, err := url.Parse(DatasourceDSN(ref, ""))
		if err != nil {
			t.Fatalf("dsn does not parse: %v", err)
		}
		if u.Host != "[fd00::1]:5433" {
			t.Errorf("host = %q, want [fd00::1]:5433", u.Host)
		}
	})
}

// Dispatch is a pure selection: the local handle for "", the registry for a
// datasource id, and nil (no coverage) whenever the datasource cannot be served.
func TestPoolFor(t *testing.T) {
	local := &sqlx.DB{}
	pools := NewDatasourcePools(local, "disable", 0)

	if got := poolFor(local, nil, ""); got != local {
		t.Error(`poolFor("") must be the local handle even without a pool registry`)
	}
	if got := poolFor(local, pools, ""); got != local {
		t.Error(`poolFor("") must be the local handle`)
	}
	// No pool registry at all: a remote region can never be served, which the
	// repos read as "no coverage" — never as a panic or a 500.
	if got := poolFor(local, nil, "d1"); got != nil {
		t.Error("a remote datasource without a pool registry must resolve to no pool")
	}
	// The registry is present but cannot read its own rows (nil local handle):
	// still no pool, still no panic.
	if got := poolFor(nil, NewDatasourcePools(nil, "", 0), "d1"); got != nil {
		t.Error("an unreadable registry must resolve to no pool")
	}
	// A nil receiver is the zero-config case and must not panic.
	var missing *DatasourcePools
	if got := missing.Pool("d1"); got != nil {
		t.Error("a nil DatasourcePools must resolve to no pool")
	}
	if got := missing.Pool(""); got != nil {
		t.Error(`a nil DatasourcePools must still answer "" with its nil local handle`)
	}
}

// Only REMOTE failures are tagged: the service degrades them to an estimate,
// while a broken local database stays a hard error.
func TestDatasourceErrTagging(t *testing.T) {
	boom := errors.New("dial tcp: connection refused")

	if err := datasourceErr("d1", boom); !errors.Is(err, ErrDatasourceUnavailable) {
		t.Errorf("remote failure %v must be tagged as ErrDatasourceUnavailable", err)
	} else if !strings.Contains(err.Error(), "connection refused") {
		t.Error("the tagged error must still carry the underlying cause")
	}

	if err := datasourceErr("", boom); errors.Is(err, ErrDatasourceUnavailable) {
		t.Error("a local-database failure must NOT be tagged as a datasource failure")
	} else if !errors.Is(err, boom) {
		t.Error("a local failure must pass through unchanged")
	}

	if err := datasourceErr("d1", nil); err != nil {
		t.Errorf("no error must stay no error, got %v", err)
	}
	if err := noPoolErr("d1"); !errors.Is(err, ErrDatasourceUnavailable) {
		t.Error("a region with no usable pool must be tagged as a datasource failure")
	}
}
