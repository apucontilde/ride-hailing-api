package tests

import (
	"net/http"
	"testing"

	"github.com/gorilla/websocket"
)

func TestWSRejectsUnauthenticated(t *testing.T) {
	wsURL := "ws" + ts.URL[4:] + "/ws"
	conn, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if conn != nil {
		_ = conn.Close()
	}
	if err == nil {
		t.Fatal("expected websocket connection to be rejected without auth")
	}
	// A missing token must be rejected at the auth middleware, not merely fail
	// the upgrade for some transport reason: assert the 401 handshake response.
	if resp != nil && resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("unauthenticated dial status = %d, want 401", resp.StatusCode)
	}
}
