package tests

import (
	"os"
	"testing"

	"ride-hailing-api/tests/testutil"
)

var ts *testutil.TestServer

func TestMain(m *testing.M) {
	ts, _ = testutil.NewTestServerE()
	// os.Exit skips deferred calls, so close the server explicitly and keep
	// the test binary's exit code.
	code := m.Run()
	ts.Close()
	os.Exit(code)
}
