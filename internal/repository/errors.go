package repository

import (
	"database/sql"
	"errors"
	"fmt"

	"github.com/lib/pq"
)

// Error taxonomy. Handlers classify with errors.Is and choose a status code and
// a public message; the cause is always preserved so ErrorLogger can print it.
//
// These are the only two client-actionable outcomes a repository can report.
// Everything else is an internal failure and must reach a handler as an error
// that is NOT ErrNotFound/ErrConflict, so it becomes a 500.
var (
	// ErrNotFound: no such row, or no row the caller is allowed to see.
	ErrNotFound = errors.New("not found")

	// ErrConflict: a uniqueness or state conflict the caller could resolve —
	// duplicate email/phone, a ride already accepted, a stale state machine.
	ErrConflict = errors.New("conflict")
)

// Postgres SQLSTATEs worth telling apart. Anything else is internal: a
// connection failure must never be reported to a user as a conflict.
const (
	sqlStateUniqueViolation     = "23505"
	sqlStateForeignKeyViolation = "23503"
	sqlStateCheckViolation      = "23514"
)

// wrapDB classifies err and prefixes op for the log line.
//
// The taxonomy sentinel and the original cause are both wrapped with %w so
// that BOTH errors.Is(err, repository.ErrNotFound) and
// errors.Is(err, sql.ErrNoRows) are true. Go 1.20+ accepts multiple %w verbs
// and this module is `go 1.25.0`, so a caller can keep testing the driver error
// directly while the handler tests the taxonomy.
//
// `op` is for humans reading the log line, never for the client: keep it a
// short verb-noun ("load user by email") and do not put user input in it.
func wrapDB(op string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%s: %w: %w", op, ErrNotFound, err)
	}
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		switch pqErr.Code {
		case sqlStateUniqueViolation, sqlStateForeignKeyViolation, sqlStateCheckViolation:
			return fmt.Errorf("%s: %w: %w", op, ErrConflict, err)
		}
	}
	return fmt.Errorf("%s: %w", op, err)
}
