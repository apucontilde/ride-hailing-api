package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jmoiron/sqlx"
)

type HealthHandler struct {
	db *sqlx.DB
}

func NewHealthHandler(db *sqlx.DB) *HealthHandler {
	return &HealthHandler{db: db}
}

func (h *HealthHandler) Liveness(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

func (h *HealthHandler) Readiness(c *gin.Context) {
	status := "ok"
	code := http.StatusOK
	checks := gin.H{}

	if h.db != nil {
		if err := h.db.Ping(); err != nil {
			status = "degraded"
			code = http.StatusServiceUnavailable
			checks["database"] = err.Error()
		} else {
			checks["database"] = "ok"
		}
	} else {
		checks["database"] = "ok"
	}

	checks["redis"] = "not_configured"

	c.JSON(code, gin.H{"status": status, "checks": checks})
}
