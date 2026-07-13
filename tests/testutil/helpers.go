package testutil

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/jmoiron/sqlx"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/router"
)

type TestServer struct {
	*httptest.Server
	DB         *sqlx.DB
	Config     *config.Config
	AuthTokens map[string]string
	RiderID    string
	DriverID   string
	UserRepo   *MockUserRepo
	RideRepo   *MockRideRepo
	GeoRepo    *MockGeoRepo
	PlacesRepo *MockPlacesRepo
}

type TestResponse struct {
	*http.Response
	Body []byte
}

func NewTestServerE() (*TestServer, error) {
	cfg := config.Load()

	// Disable rate limiting for tests
	cfg.RateLimitRegister = 9999
	cfg.RateLimitLogin = 9999
	cfg.RateLimitGeneral = 9999
	cfg.RateLimitRide = 9999

	userRepo := NewMockUserRepo()
	rideRepo := NewMockRideRepo()
	geoRepo := NewMockGeoRepo()
	navRepo := NewMockNavigationRepo()
	placesRepo := NewMockPlacesRepo()

	r := router.SetupWithRepos(cfg, userRepo, rideRepo, geoRepo, navRepo, placesRepo, nil)

	ts := &TestServer{
		Server:     httptest.NewServer(r),
		Config:     cfg,
		AuthTokens: make(map[string]string),
		UserRepo:   userRepo,
		RideRepo:   rideRepo,
		GeoRepo:    geoRepo,
		PlacesRepo: placesRepo,
	}

	return ts, nil
}

func NewTestServer(t *testing.T) *TestServer {
	t.Helper()
	ts, err := NewTestServerE()
	if err != nil {
		t.Skipf("skipping: %v", err)
		return nil
	}
	return ts
}

func (ts *TestServer) PostJSON(path string, body interface{}) *TestResponse {
	return ts.DoRequest("POST", path, ts.AuthTokens["rider"], body)
}

func (ts *TestServer) PutJSON(path string, body interface{}) *TestResponse {
	return ts.DoRequest("PUT", path, ts.AuthTokens["rider"], body)
}

func (ts *TestServer) Get(path string) *TestResponse {
	return ts.DoRequest("GET", path, ts.AuthTokens["rider"], nil)
}

func (ts *TestServer) Delete(path string) *TestResponse {
	return ts.DoRequest("DELETE", path, ts.AuthTokens["rider"], nil)
}

func (ts *TestServer) DoRequest(method, path, token string, body interface{}) *TestResponse {
	var reqBody []byte
	if body != nil {
		reqBody, _ = json.Marshal(body)
	}

	req, _ := http.NewRequest(method, ts.URL+path, bytes.NewReader(reqBody))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		panic(err)
	}

	buf := new(bytes.Buffer)
	buf.ReadFrom(resp.Body)
	resp.Body.Close()

	return &TestResponse{Response: resp, Body: buf.Bytes()}
}

func (ts *TestServer) LoginAsRider(email, password string) {
	resp := ts.DoRequest("POST", "/api/v1/auth/login", "", map[string]string{
		"email":    email,
		"password": password,
	})
	var result struct {
		AccessToken string `json:"access_token"`
	}
	json.Unmarshal(resp.Body, &result)
	ts.AuthTokens["rider"] = result.AccessToken
}

func (r *TestResponse) AssertStatus(t *testing.T, expected int) {
	t.Helper()
	if r.StatusCode != expected {
		t.Errorf("expected status %d, got %d", expected, r.StatusCode)
	}
}

func (r *TestResponse) AssertJSONHas(t *testing.T, key string, expected ...interface{}) {
	t.Helper()

	var body map[string]interface{}
	json.Unmarshal(r.Body, &body)

	keys := nestedKeys(key)
	current := any(body)
	for i, k := range keys {
		val, exists := getKey(current, k)
		if !exists {
			t.Errorf("expected key %s in response body", key)
			return
		}
		if len(expected) > 0 && i == len(keys)-1 {
			if val != expected[0] {
				t.Errorf("expected %s=%v, got %v", key, expected[0], val)
			}
		}
		current = val
	}
}

func getKey(current any, k string) (any, bool) {
	switch v := current.(type) {
	case map[string]interface{}:
		val, ok := v[k]
		return val, ok
	case []interface{}:
		idx := 0
		if _, err := fmt.Sscanf(k, "%d", &idx); err == nil && idx >= 0 && idx < len(v) {
			return v[idx], true
		}
		return nil, false
	default:
		return nil, false
	}
}

func (r *TestResponse) AssertJSONMissing(t *testing.T, key string) {
	t.Helper()

	var body map[string]interface{}
	json.Unmarshal(r.Body, &body)

	keys := nestedKeys(key)
	current := any(body)
	found := true
	for _, k := range keys {
		val, exists := getKey(current, k)
		if !exists {
			found = false
			break
		}
		current = val
	}

	if found {
		t.Errorf("expected key %s to be missing from response, but it was present", key)
	}
}

func nestedKeys(key string) []string {
	var keys []string
	current := ""
	for _, ch := range key {
		if ch == '.' {
			if current != "" {
				keys = append(keys, current)
				current = ""
			}
		} else {
			current += string(ch)
		}
	}
	if current != "" {
		keys = append(keys, current)
	}
	return keys
}

func ParseJSON(t *testing.T, data []byte, v interface{}) {
	t.Helper()
	if err := json.Unmarshal(data, v); err != nil {
		t.Fatalf("failed to parse json: %v", err)
	}
}

func (ts *TestServer) DialWS(t *testing.T, token string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + ts.URL[4:] + "/ws"
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, header)
	if err != nil {
		t.Fatalf("websocket dial failed: %v", err)
	}
	return conn
}

func ReadWSMessage(t *testing.T, conn *websocket.Conn) map[string]interface{} {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, msgBytes, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("websocket read failed: %v", err)
	}
	var msg map[string]interface{}
	if err := json.Unmarshal(msgBytes, &msg); err != nil {
		t.Fatalf("failed to parse ws message: %v", err)
	}
	return msg
}
