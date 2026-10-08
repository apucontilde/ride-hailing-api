package tests

import (
	"os"
	"testing"

	"ride-hailing-api/tests/testutil"
)

// ts is a single server shared by every test in package tests. Its mock repos
// keep state across tests, so tests that seed drivers/positions must use
// coordinates away from the ones other tests rely on, and tests that inject a
// one-shot failure must consume it promptly. This coupling is intentional: a
// per-test server would need a full DB-free rewire and is deliberately not done
// here (see tests/UNIT_AUDIT.md S6). Tests needing isolated state build their
// own server via testutil.NewStrictTestServer/NewTestServerWithNav.
var ts *testutil.TestServer

func TestMain(m *testing.M) {
	ts, _ = testutil.NewTestServerE()
	// os.Exit skips deferred calls, so close the server explicitly and keep
	// the test binary's exit code.
	code := m.Run()
	ts.Close()
	os.Exit(code)
}
