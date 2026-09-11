package middleware

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

type fieldPattern struct {
	re    *regexp.Regexp
	field string
}

var sensitivePatterns []fieldPattern

func init() {
	fields := []string{`password`, `new_password`, `refresh_token`, `reset_token`, `token`, `access_token`}
	for _, f := range fields {
		sensitivePatterns = append(sensitivePatterns, fieldPattern{
			re:    regexp.MustCompile(`"` + f + `"\s*:\s*"[^"]*"`),
			field: f,
		})
	}
}

func maskSensitive(body []byte) []byte {
	s := string(body)
	for _, fp := range sensitivePatterns {
		replacement := `"` + fp.field + `":"***"`
		s = fp.re.ReplaceAllString(s, replacement)
	}
	return []byte(s)
}

// maskQueryTokens redacts credentials that travel in the URL query string
// (e.g. /ws?access_token=...), which the URI is otherwise logged verbatim.
func maskQueryTokens(uri string) string {
	if !strings.Contains(uri, "?") {
		return uri
	}
	u, err := url.ParseRequestURI(uri)
	if err != nil {
		return uri
	}
	q := u.Query()
	masked := false
	for _, key := range []string{"access_token", "token"} {
		if q.Has(key) {
			q.Set(key, "***")
			masked = true
		}
	}
	if !masked {
		return uri
	}
	return u.Path + "?" + q.Encode()
}

type bodyWriter struct {
	gin.ResponseWriter
	body *bytes.Buffer
}

func (w *bodyWriter) Write(b []byte) (int, error) {
	w.body.Write(b)
	return w.ResponseWriter.Write(b)
}

const maxLogBody = 2048

// DebugLogger logs request/response bodies. It is only registered when
// DebugLogging is enabled (see router.SetupWithRepos), so it carries no
// overhead in production. Response bodies are captured by wrapping the
// writer, so each RES line is emitted before the payload reaches the client.
//
// Errors recorded via c.Error(err) are logged by the always-on ErrorLogger
// middleware; handlers keep returning a stable public message in the response
// while the raw error is printed separately with its request context.
func DebugLogger() gin.HandlerFunc {
	return func(c *gin.Context) {
		method := c.Request.Method
		reqID := ensureRequestID(c)
		uri := maskQueryTokens(c.Request.URL.RequestURI())

		var reqLog []string
		if c.Request.Body != nil {
			bodyBytes, _ := io.ReadAll(c.Request.Body)
			c.Request.Body = io.NopCloser(bytes.NewBuffer(bodyBytes))

			if len(bodyBytes) > 0 && !isWebSocketUpgrade(c) {
				masked := maskSensitive(bodyBytes)
				if len(masked) > maxLogBody {
					masked = append(masked[:maxLogBody], []byte("... (truncated)")...)
				}
				reqLog = append(reqLog, "req_body="+string(masked))
			}
		}
		if len(reqLog) > 0 {
			log.Printf("[DEBUG] REQ %s %s %s request_id=%s", method, uri, strings.Join(reqLog, " "), reqID)
		} else {
			log.Printf("[DEBUG] REQ %s %s request_id=%s", method, uri, reqID)
		}

		bw := &bodyWriter{body: &bytes.Buffer{}, ResponseWriter: c.Writer}
		c.Writer = bw

		c.Next()

		var respLog string
		if respBody := bw.body.Bytes(); len(respBody) > 0 && !isWebSocketUpgrade(c) {
			masked := maskSensitive(respBody)
			if len(masked) > maxLogBody {
				masked = append(masked[:maxLogBody], []byte("... (truncated)")...)
			}
			respLog = " resp_body=" + string(masked)
		}

		log.Printf("[DEBUG] RES %s %s => %d request_id=%s%s", method, uri, c.Writer.Status(), reqID, respLog)
	}
}

// ensureRequestID returns the request's correlation id, generating and
// setting X-Request-ID plus the "request_id" context value on first use so
// all middlewares log the same id for a given request.
func ensureRequestID(c *gin.Context) string {
	if id, ok := c.Get("request_id"); ok {
		if s, ok := id.(string); ok && s != "" {
			return s
		}
	}
	id := c.GetHeader("X-Request-ID")
	if id == "" {
		id = newRequestID()
		c.Header("X-Request-ID", id)
	}
	c.Set("request_id", id)
	return id
}

func newRequestID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("req-%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b)
}

func isWebSocketUpgrade(c *gin.Context) bool {
	return c.Request.Header.Get("Upgrade") == "websocket"
}
