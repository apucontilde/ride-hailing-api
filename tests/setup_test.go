package tests

import (
	"os"
	"testing"

	"ride-hailing-api/tests/testutil"
)

var ts *testutil.TestServer

func TestMain(m *testing.M) {
	ts, _ = testutil.NewTestServerE()
	defer ts.Close()
	os.Exit(m.Run())
}
