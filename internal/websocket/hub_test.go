package websocket

import (
	"testing"
	"time"
)

// newTestClient returns a client registered in hub's map at the given lastSeen
// age. The hub map is manipulated directly: these tests prove the presence
// JUDGEMENT (IsConnected), not the WebSocket handshake, which needs a live
// connection and is covered end-to-end in tests/.
func addClient(h *Hub, userID string, seenAge time.Duration) *Client {
	c := &Client{UserID: userID, Role: "driver"}
	c.lastSeen.Store(time.Now().Add(-seenAge).UnixNano())
	h.clients[userID] = c
	return c
}

// TestHubIsConnectedLiveness pins api_plans [dispatch]_offer_path_fixes §A3:
// IsConnected must read map presence THROUGH the per-client liveness deadline,
// so a half-open socket stops counting as connected and a touch (any inbound
// frame, ping, or pong) refreshes presence.
func TestHubIsConnectedLiveness(t *testing.T) {
	cases := []struct {
		name    string
		setup   func(h *Hub) *Client
		userID  string
		want    bool
		touches bool // touch the returned client before asking
	}{
		{
			name:   "absent client is not connected",
			setup:  func(h *Hub) *Client { return nil },
			userID: "nobody",
			want:   false,
		},
		{
			name: "fresh client is connected",
			setup: func(h *Hub) *Client {
				return addClient(h, "d1", 0)
			},
			userID: "d1",
			want:   true,
		},
		{
			name: "client seen just inside the TTL is connected",
			setup: func(h *Hub) *Client {
				return addClient(h, "d2", clientLivenessTTL-time.Second)
			},
			userID: "d2",
			want:   true,
		},
		{
			name: "stale client past the TTL is not connected",
			setup: func(h *Hub) *Client {
				return addClient(h, "d3", clientLivenessTTL+time.Second)
			},
			userID: "d3",
			want:   false,
		},
		{
			name: "a touch refreshes a stale client",
			setup: func(h *Hub) *Client {
				return addClient(h, "d4", clientLivenessTTL+time.Minute)
			},
			userID:  "d4",
			want:    true,
			touches: true,
		},
		{
			name: "touching an evicted client does not refresh its successor",
			setup: func(h *Hub) *Client {
				// The old client is evicted (reconnect), the successor that
				// replaced it has gone quiet: the old client's late inbound
				// frames must not make the successor read as live.
				old := addClient(h, "d5", 0)
				addClient(h, "d5", clientLivenessTTL+time.Second)
				old.touch()
				return h.clients["d5"]
			},
			userID: "d5",
			want:   false,
		},
		{
			name: "a touch on the registered client refreshes it",
			setup: func(h *Hub) *Client {
				c := addClient(h, "d6", clientLivenessTTL+time.Minute)
				return c
			},
			userID:  "d6",
			want:    true,
			touches: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := NewHub()
			c := tc.setup(h)
			if tc.touches && c != nil {
				c.touch()
			}
			if got := h.IsConnected(tc.userID); got != tc.want {
				t.Errorf("IsConnected(%q) = %v, want %v", tc.userID, got, tc.want)
			}
		})
	}
}

// TestClientTouchMovesLastSeen guards the refresh primitive itself: a touch
// must move lastSeen strictly forward so a stream of frames keeps a client
// inside the liveness window.
func TestClientTouchMovesLastSeen(t *testing.T) {
	c := &Client{UserID: "d", Role: "driver"}
	c.lastSeen.Store(time.Now().Add(-time.Hour).UnixNano())
	before := c.lastSeenAt()
	c.touch()
	if !c.lastSeenAt().After(before) {
		t.Errorf("lastSeenAt() = %v, want strictly after %v", c.lastSeenAt(), before)
	}
}
