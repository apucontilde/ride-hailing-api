package websocket

import (
	"log"
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

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
	mu      sync.RWMutex
	clients map[string]*Client
}

func NewHub() *Hub {
	return &Hub{
		clients: make(map[string]*Client),
	}
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
		_, _, err := conn.ReadMessage()
		if err != nil {
			break
		}
	}
}

func (h *Hub) SendToUser(userID string, msg interface{}) {
	h.mu.RLock()
	client, ok := h.clients[userID]
	h.mu.RUnlock()
	if ok {
		client.SendJSON(msg)
	}
}

func (h *Hub) BroadcastToRole(role string, msg interface{}) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, client := range h.clients {
		if client.Role == role {
			client.SendJSON(msg)
		}
	}
}
