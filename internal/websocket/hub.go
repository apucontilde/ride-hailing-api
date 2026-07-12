package websocket

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

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

	h.mu.Lock()
	if existing, ok := h.clients[userIDStr]; ok {
		existing.Conn.Close()
	}
	client := &Client{UserID: userIDStr, Role: role.(string), Conn: conn}
	h.clients[userIDStr] = client
	h.mu.Unlock()

	log.Printf("websocket connected: user=%s role=%s", userIDStr, role)

	defer func() {
		h.mu.Lock()
		delete(h.clients, userIDStr)
		h.mu.Unlock()
		conn.Close()
	}()

	for {
		_, msgBytes, err := conn.ReadMessage()
		if err != nil {
			break
		}

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

func (h *Hub) IsConnected(userID string) bool {
	h.mu.RLock()
	_, ok := h.clients[userID]
	h.mu.RUnlock()
	return ok
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
