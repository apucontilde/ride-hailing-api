package websocket

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

// clientLivenessTTL is how long a registered client keeps reading as connected
// without any inbound traffic (a frame, a ping, or a pong). It must sit above
// the driver keepalive cadence (25 s, driver_app_plans
// [dispatch]_keepalive_and_offer_reliability) and below the dispatch offer
// window (30 s, internal/service/dispatch_observability.go), so a live driver
// stays visible while a half-open socket stops counting as connected well
// before an offer would be wasted on it (api_plans [dispatch]_offer_path_fixes
// §A3).
const clientLivenessTTL = 28 * time.Second

// serverPingInterval is how often the hub sends a protocol-level ping on every
// connection. The pong reply refreshes lastSeen, so a client that stays quiet
// at the application level (a rider app has no keepalive) still reads as
// connected while the TCP path works, and goes stale when it does not.
const serverPingInterval = 10 * time.Second

// controlWriteTimeout bounds the individual WriteControl calls below. It is
// not a read deadline: an idle connection is never closed for silence, only
// judged by clientLivenessTTL at the moment presence is asked for.
const controlWriteTimeout = 5 * time.Second

type DispatchHandler interface {
	HandleAccept(driverID, rideID string) error
	HandleDecline(driverID, rideID string)
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type Client struct {
	UserID string
	Role   string
	Conn   *websocket.Conn
	mu     sync.Mutex
	// lastSeen is the wall-clock time (unix nanoseconds, atomic so the read
	// loop and the ping ticker can refresh it without the write mutex) of the
	// last inbound frame or control frame from this client. IsConnected judges
	// presence on it, not on map entry alone.
	lastSeen atomic.Int64
}

// touch records inbound activity on this client. It is called from the read
// loop (every frame, ping, and pong) and is safe from any goroutine.
func (c *Client) touch() {
	c.lastSeen.Store(time.Now().UnixNano())
}

// lastSeenAt returns the time of the client's last observed activity.
func (c *Client) lastSeenAt() time.Time {
	return time.Unix(0, c.lastSeen.Load())
}

func (c *Client) SendJSON(v interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.Conn.WriteJSON(v)
}

type Hub struct {
	mu              sync.RWMutex
	clients         map[string]*Client
	dispatchHandler DispatchHandler
}

func NewHub() *Hub {
	return &Hub{
		clients: make(map[string]*Client),
	}
}

func (h *Hub) SetDispatchHandler(dh DispatchHandler) {
	h.dispatchHandler = dh
}

func (h *Hub) HandleWS(c *gin.Context) {
	userID, _ := c.Get("user_id")
	role, _ := c.Get("role")

	conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("websocket upgrade failed: %v", err)
		return
	}

	userIDStr := userID.(string)

	client := &Client{UserID: userIDStr, Role: role.(string), Conn: conn}
	// Freshly registered clients read as connected: the handshake itself is the
	// proof of liveness.
	client.touch()

	// Protocol-level keepalive: a ping refreshes lastSeen on arrival, and the
	// pong reply (auto-sent by any conforming client, including the Flutter
	// WebSocket implementations) refreshes it again on the way back. Together
	// with the app-level "ping" frame below, this is what makes lastSeen a
	// liveness signal rather than a connection-age counter.
	conn.SetPingHandler(func(appData string) error {
		client.touch()
		return conn.WriteControl(websocket.PongMessage, []byte(appData), time.Now().Add(controlWriteTimeout))
	})
	conn.SetPongHandler(func(appData string) error {
		client.touch()
		return nil
	})

	h.mu.Lock()
	if existing, ok := h.clients[userIDStr]; ok {
		// Evicting the old socket: a Close error is not actionable here.
		_ = existing.Conn.Close()
	}
	h.clients[userIDStr] = client
	h.mu.Unlock()

	log.Printf("websocket connected: user=%s role=%s", userIDStr, role)

	// Server-initiated pings keep quiet clients (rider apps have no heartbeat)
	// inside the liveness window while the connection is genuinely alive.
	pingDone := make(chan struct{})
	defer close(pingDone)
	go func() {
		ticker := time.NewTicker(serverPingInterval)
		defer ticker.Stop()
		for {
			select {
			case <-pingDone:
				return
			case <-ticker.C:
				// WriteControl is safe for concurrent use with the read loop's
				// pongs and the dispatch path's WriteJSON calls.
				if err := conn.WriteControl(websocket.PingMessage, nil, time.Now().Add(controlWriteTimeout)); err != nil {
					// A failed write ends the ticker; the read loop notices the
					// dead connection and unregisters the client as before.
					return
				}
			}
		}
	}()

	defer func() {
		h.mu.Lock()
		// Delete only OUR registration: a reconnect may have already evicted
		// this client and installed a newer one under the same user id, and a
		// blind delete here would unregister the new socket a moment after it
		// registered — exactly the reconnect gap dispatch then skips.
		if current, ok := h.clients[userIDStr]; ok && current == client {
			delete(h.clients, userIDStr)
		}
		h.mu.Unlock()
		_ = conn.Close()
	}()

	for {
		_, msgBytes, err := conn.ReadMessage()
		if err != nil {
			break
		}
		// Every inbound frame is proof the socket is alive.
		client.touch()

		var incoming struct {
			Type string          `json:"type"`
			Data json.RawMessage `json:"data"`
		}
		if json.Unmarshal(msgBytes, &incoming) != nil {
			continue
		}

		switch incoming.Type {
		case "ride.accept":
			var data struct {
				RideID string `json:"ride_id"`
			}
			if json.Unmarshal(incoming.Data, &data) == nil && h.dispatchHandler != nil {
				if err := h.dispatchHandler.HandleAccept(client.UserID, data.RideID); err != nil {
					log.Printf("failed to handle ride accept: %v", err)
				}
			}
		case "ride.decline":
			var data struct {
				RideID string `json:"ride_id"`
			}
			if json.Unmarshal(incoming.Data, &data) == nil && h.dispatchHandler != nil {
				h.dispatchHandler.HandleDecline(client.UserID, data.RideID)
			}
		case "ping":
			if err := client.SendJSON(map[string]string{"type": "pong"}); err != nil {
				log.Printf("failed to send pong: %v", err)
			}
		}
	}
}

// IsConnected reports whether userID holds a live socket: registered in the
// hub AND seen within clientLivenessTTL. Map presence alone cannot tell a live
// connection from a stale entry behind a half-open TCP connection, and dispatch
// must not spend an offer on the latter (api_plans [dispatch]_offer_path_fixes
// §A3, bug #11).
func (h *Hub) IsConnected(userID string) bool {
	h.mu.RLock()
	client, ok := h.clients[userID]
	h.mu.RUnlock()
	if !ok {
		return false
	}
	return time.Since(client.lastSeenAt()) <= clientLivenessTTL
}

func (h *Hub) SendToUser(userID string, msg interface{}) {
	h.mu.RLock()
	client, ok := h.clients[userID]
	h.mu.RUnlock()
	if ok {
		if err := client.SendJSON(msg); err != nil {
			log.Printf("failed to send message to user %s: %v", userID, err)
		}
	}
}

func (h *Hub) BroadcastToRole(role string, msg interface{}) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, client := range h.clients {
		if client.Role == role {
			if err := client.SendJSON(msg); err != nil {
				log.Printf("failed to send message to role %s: %v", role, err)
			}
		}
	}
}
