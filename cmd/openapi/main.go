// Command openapi reconciles the swag-generated OpenAPI document against the
// routes actually registered in the router, so the spec always matches the
// code. It fills in any route swag could not associate with an annotated
// handler, drops routes that no longer exist, and guarantees unique
// operationIds.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/gin-gonic/gin"
	"gopkg.in/yaml.v3"

	"ride-hailing-api/internal/config"
	"ride-hailing-api/internal/router"
)

type route struct {
	method string
	path   string
}

func main() {
	specPath := "docs/swagger.json"
	if len(os.Args) > 1 {
		specPath = os.Args[1]
	}

	gin.SetMode(gin.ReleaseMode)
	engine := router.SetupWithRepos(&config.Config{
		PlacesMaxRadiusM:   50000,
		PlacesDefaultLimit: 10,
	}, nil, nil, nil, nil, nil, nil)

	raw, err := os.ReadFile(specPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "openapi: %v\n", err)
		os.Exit(1)
	}

	var spec map[string]any
	if jsonErr := json.Unmarshal(raw, &spec); jsonErr != nil {
		fmt.Fprintf(os.Stderr, "openapi: invalid JSON in %s: %v\n", specPath, jsonErr)
		os.Exit(1)
	}

	paths, ok := spec["paths"].(map[string]any)
	if !ok {
		paths = map[string]any{}
		spec["paths"] = paths
	}

	// Enumerate the routes actually registered in the router.
	runtime := map[string]bool{}
	var runtimeList []route
	for _, r := range engine.Routes() {
		if r.Method == "HEAD" || r.Method == "OPTIONS" {
			continue
		}
		openPath := ginPathToOpen(r.Path)
		if strings.HasPrefix(openPath, "/docs") {
			continue // swagger UI / spec endpoints are not part of the API surface
		}
		key := normalizeKey(r.Method, openPath)
		if runtime[key] {
			continue
		}
		runtime[key] = true
		runtimeList = append(runtimeList, route{method: r.Method, path: openPath})
	}

	// Canonicalize spec path keys (strip trailing slashes) so empty-suffix
	// registrations like rides.POST("") match their gin runtime path.
	for path := range paths {
		trimmed := strings.TrimRight(path, "/")
		if trimmed == path {
			continue
		}
		target := ensureMap(paths, trimmed)
		for method, op := range paths[path].(map[string]any) {
			if _, exists := target[method]; !exists {
				target[method] = op
			}
		}
		delete(paths, path)
	}

	// Fill in any registered route swag missed.
	for _, rt := range runtimeList {
		item := ensureMap(paths, rt.path)
		method := strings.ToLower(rt.method)
		if _, exists := item[method]; exists {
			continue
		}
		op := map[string]any{
			"tags":        []string{tagFor(rt.path)},
			"summary":     rt.method + " " + rt.path,
			"operationId": defaultOpID(rt.method, rt.path),
			"responses": map[string]any{
				"200": map[string]any{"description": "OK"},
			},
		}
		if !isPublic(rt.method, rt.path) {
			op["security"] = []any{map[string]any{"BearerAuth": []any{}}}
		}
		if ps := pathParams(rt.path); len(ps) > 0 {
			params := make([]any, 0, len(ps))
			for _, p := range ps {
				params = append(params, map[string]any{
					"name":     p,
					"in":       "path",
					"required": true,
					"schema":   map[string]any{"type": "string"},
				})
			}
			op["parameters"] = params
		}
		item[method] = op
	}

	// Drop operations whose route is no longer registered.
	for path := range paths {
		item, _ := paths[path].(map[string]any)
		for method := range item {
			if !runtime[normalizeKey(method, path)] {
				delete(item, method)
			}
		}
		if len(item) == 0 {
			delete(paths, path)
		}
	}

	// Guarantee unique operationIds.
	counts := map[string]int{}
	for path, rawItem := range paths {
		for method, rawOp := range rawItem.(map[string]any) {
			op, _ := rawOp.(map[string]any)
			if op == nil {
				continue
			}
			id, _ := op["operationId"].(string)
			if id == "" {
				id = defaultOpID(strings.ToUpper(method), path)
			}
			counts[id]++
			if counts[id] > 1 {
				id = fmt.Sprintf("%s-%d", id, counts[id])
			}
			op["operationId"] = id
		}
	}

	out, err := json.MarshalIndent(spec, "", "  ")
	if err != nil {
		fmt.Fprintf(os.Stderr, "openapi: %v\n", err)
		os.Exit(1)
	}
	if writeErr := os.WriteFile(specPath, append(out, '\n'), 0o644); writeErr != nil {
		fmt.Fprintf(os.Stderr, "openapi: %v\n", writeErr)
		os.Exit(1)
	}

	yamlPath := strings.TrimSuffix(specPath, ".json") + ".yaml"
	yamlOut, err := yaml.Marshal(spec)
	if err != nil {
		fmt.Fprintf(os.Stderr, "openapi: %v\n", err)
		os.Exit(1)
	}
	var back map[string]any
	if err := yaml.Unmarshal(yamlOut, &back); err != nil {
		fmt.Fprintf(os.Stderr, "openapi: generated YAML failed to parse: %v\n", err)
		os.Exit(1)
	}
	if err := os.WriteFile(yamlPath, yamlOut, 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "openapi: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("openapi: reconciled %d operations with %s and %s\n", len(runtimeList), specPath, yamlPath)
}

var publicRoutes = map[string]bool{
	"GET /health":                       true,
	"GET /health/ready":                 true,
	"GET /api/v1/version":               true,
	"POST /api/v1/auth/register":        true,
	"POST /api/v1/auth/login":           true,
	"POST /api/v1/auth/refresh":         true,
	"POST /api/v1/auth/forgot-password": true,
	"POST /api/v1/auth/reset-password":  true,
	"POST /api/v1/auth/social":          true,
}

func isPublic(method, path string) bool {
	return publicRoutes[method+" "+strings.TrimRight(path, "/")]
}

func normalizeKey(method, path string) string {
	return strings.ToLower(method) + " " + strings.TrimRight(path, "/")
}

func ensureMap(m map[string]any, key string) map[string]any {
	item, ok := m[key].(map[string]any)
	if !ok {
		item = map[string]any{}
		m[key] = item
	}
	return item
}

// ginPathToOpen converts a gin route path (:id) to OpenAPI form ({id}).
func ginPathToOpen(p string) string {
	segments := strings.Split(p, "/")
	var b strings.Builder
	b.Grow(len(p))
	for i, s := range segments {
		if i > 0 {
			b.WriteByte('/')
		}
		if len(s) > 1 && (s[0] == ':' || s[0] == '*') {
			b.WriteByte('{')
			b.WriteString(s[1:])
			b.WriteByte('}')
		} else {
			b.WriteString(s)
		}
	}
	return b.String()
}

func pathParams(p string) []string {
	var out []string
	for _, s := range strings.Split(p, "/") {
		if len(s) > 2 && s[0] == '{' && s[len(s)-1] == '}' {
			out = append(out, s[1:len(s)-1])
		}
	}
	return out
}

func tagFor(path string) string {
	segs := strings.Split(strings.Trim(path, "/"), "/")
	for _, s := range segs {
		if strings.HasPrefix(s, "{") || s == "api" || s == "v1" || s == "ws" {
			continue
		}
		return s
	}
	return "default"
}

func defaultOpID(method, path string) string {
	var parts []string
	for _, s := range strings.Split(strings.Trim(path, "/"), "/") {
		if strings.HasPrefix(s, "{") {
			parts = append(parts, "ByID")
		} else if s != "api" && s != "v1" {
			parts = append(parts, s)
		}
	}
	base := strings.Join(parts, "-")
	if base == "" {
		base = "Root"
	}
	first := strings.ToUpper(base[:1])
	return strings.ToLower(method) + first + base[1:]
}
