package repository

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/lib/pq"
	"github.com/lib/pq/pqerror"
)

func TestWrapDBNil(t *testing.T) {
	if got := wrapDB("op", nil); got != nil {
		t.Fatalf("wrapDB(%q, nil) = %v, want nil", "op", got)
	}
}

func TestWrapDBNotFound(t *testing.T) {
	got := wrapDB("load user", sql.ErrNoRows)
	if !errors.Is(got, ErrNotFound) {
		t.Errorf("wrapDB(sql.ErrNoRows) not ErrNotFound: %v", got)
	}
	if !errors.Is(got, sql.ErrNoRows) {
		t.Errorf("wrapDB(sql.ErrNoRows) lost sql.ErrNoRows (co-wrap dropped): %v", got)
	}
	if errors.Is(got, ErrConflict) {
		t.Errorf("wrapDB(sql.ErrNoRows) wrongly ErrConflict: %v", got)
	}
}

func TestWrapDBConflict(t *testing.T) {
	for _, code := range []string{"23505", "23503", "23514"} {
		got := wrapDB("op", &pq.Error{Code: pqerror.Code(code)})
		if !errors.Is(got, ErrConflict) {
			t.Errorf("wrapDB(%s) not ErrConflict: %v", code, got)
		}
		if errors.Is(got, ErrNotFound) {
			t.Errorf("wrapDB(%s) wrongly ErrNotFound: %v", code, got)
		}
	}
}

func TestWrapDBConnectionFailureIsNotClientError(t *testing.T) {
	// 08006 = connection_failure. The regression test for series failure #1:
	// an outage must never be classifiable as a client error.
	got := wrapDB("op", &pq.Error{Code: pqerror.Code("08006")})
	if errors.Is(got, ErrNotFound) {
		t.Errorf("connection failure classified as ErrNotFound: %v", got)
	}
	if errors.Is(got, ErrConflict) {
		t.Errorf("connection failure classified as ErrConflict: %v", got)
	}
}

func TestWrapDBSeeThroughIntermediateWraps(t *testing.T) {
	inner := wrapDB("op", &pq.Error{Code: pqerror.Code("23505")})
	wrapped := fmt.Errorf("context: %w", inner)
	if !errors.Is(wrapped, ErrConflict) {
		t.Errorf("errors.As/Is did not see through intermediate wrap: %v", wrapped)
	}
	if errors.Is(wrapped, ErrNotFound) {
		t.Errorf("intermediate wrap misclassified as ErrNotFound: %v", wrapped)
	}
}

func TestWrapDBConstraintNamePreserved(t *testing.T) {
	err := wrapDB("op", &pq.Error{
		Code:       pqerror.Code("23505"),
		Message:    "duplicate key value violates unique constraint",
		Constraint: "users_email_key",
	})

	// The constraint name must stay available to the logger. lib/pq v1.12.3's
	// Error() text prints only "pq: <message> (<code>)" and drops the
	// Constraint field, so the detail is preserved on the wrapped *pq.Error
	// itself (recoverable via errors.As), which is what stage 02's ErrorLogger
	// reads for the log line.
	var pqErr *pq.Error
	if !errors.As(err, &pqErr) {
		t.Fatalf("wrapped error no longer carries *pq.Error: %v", err)
	}
	if pqErr.Constraint != "users_email_key" {
		t.Errorf("constraint name lost from wrapped *pq.Error: %q", pqErr.Constraint)
	}
	if !strings.Contains(err.Error(), "op") {
		t.Errorf("op missing from wrapped error text: %v", err)
	}
}
