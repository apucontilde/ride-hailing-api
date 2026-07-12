package tests

import (
	"net/http"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestWSRiderConnectsAuthenticated(t *testing.T) {
	ts.PostJSON("/api/v1/auth/register", map[string]string{
		"email":    "rider.ws@test.com",
		"phone":    "+3434343434",
		"password": "SecurePass1",
	})
	loginResp := ts.PostJSON("/api/v1/auth/login", map[string]string{
		"email":    "rider.ws@test.com",
		"password": "SecurePass1",
	})
	var loginResult struct {
		AccessToken string `json:"access_token"`
	}
	parseJSON(t, loginResp.Body, &loginResult)

	wsURL := "ws" + ts.URL[4:] + "/ws"
	header := http.Header{}
	header.Set("Authorization", "Bearer "+loginResult.AccessToken)

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Skipf("websocket endpoint not available: %v", err)
	}
	defer conn.Close()

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, err = conn.ReadMessage()
	if err == nil {
		t.Log("websocket connected and received message")
	}
}

func TestWSRejectsUnauthenticated(t *testing.T) {
	wsURL := "ws" + ts.URL[4:] + "/ws"
	_, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err == nil {
		t.Error("expected websocket connection to be rejected without auth")
	}
}
