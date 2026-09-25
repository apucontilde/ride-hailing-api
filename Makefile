.PHONY: all build run test test-integration benchmark bench-integration lint clean docker-up docker-down migrate-up migrate-down seed import-osm download-osm download-osm-san-jose export-places openapi flutter-bootstrap flutter-analyze flutter-test

APP_NAME=ride-hailing-api
BUILD_DIR=./build

# Database connection (override via env or .env)
DB_HOST     ?= localhost
DB_PORT     ?= 5432
DB_USER     ?= ridehail
DB_PASSWORD ?= ridehail_pass
DB_NAME     ?= ridehailing
DB_SSLMODE  ?= disable
DATABASE_URL ?= postgres://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB_NAME)?sslmode=$(DB_SSLMODE)

all: build

build:
	go build -o $(BUILD_DIR)/$(APP_NAME) ./cmd/server

run:
	DEBUG_LOGGING=true go run ./cmd/server

test:
	go test -v -count=1 ./...

test-integration:
	go test -v -count=1 -tags=integration ./...

# Routing engine benchmarks (native A* + spatial snap index); the baseline for
# the pgRouting comparison gate in api_plans/03.
benchmark:
	go test -count=1 -bench=. -benchmem ./internal/routing/

# DB-backed routing benchmarks (pgRouting engine, plan 03+). Requires the DB.
bench-integration:
	go test -count=1 -tags=integration -bench=. -benchmem ./internal/...

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BUILD_DIR)

seed:
	psql "$(DATABASE_URL)" -f scripts/seed.sql

# Region-scoped import (api_plans/05): --region is the only importable unit and
# defaults to cr-sj, so these two targets keep their old behavior. Region/datasource
# flags are intentionally NOT forwarded — the script is the arg-bearing entrypoint.
import-osm:
	./scripts/import-road-network.sh

# Same import, forced re-run of osm2pgrouting for THAT region only.
import-osm-force:
	./scripts/import-road-network.sh --force

# To import a different OSM extract (e.g. whole country):
#	make import-osm-force OSM_INPUT=data/costa-rica-latest.osm.pbf
# or call ./scripts/import-road-network.sh --force <path/to/input.osm.pbf> directly.
#
# To import a SECOND region, download a clip for it and call the script directly
# (the script registers the region, then imports it region-scoped — no global
# TRUNCATE, so co-resident regions survive):
#	./scripts/download-osm.sh --region cr-lc --bbox -84.10,9.95,-83.95,10.05
#	./scripts/import-road-network.sh --region cr-lc \
#	    --bbox -84.10,9.95,-83.95,10.05 \
#	    --name "Ciudad Colón" --parent cr --default data/cr-lc.osm.pbf
# Re-import just that region: same command with --force.
# Rows for a region can also live in another Postgres (plan 06) — pass
# --datasource <id> of a row that already exists in routing_datasources.

download-osm:
	./scripts/download-osm.sh

# Same download, but also clips the extract to the San José bbox.
download-osm-san-jose:
	./scripts/download-osm.sh --san-jose

# Clip a region other than San José (writes data/<region>.osm.pbf):
#	./scripts/download-osm.sh --region cr-lc --bbox -84.10,9.95,-83.95,10.05

export-places:
	./scripts/export-places.sh
# To export from a different OSM extract:
#	make export-places OSM_INPUT=data/costa-rica-latest.osm.pbf
# or call ./scripts/export-places.sh <path/to/input.osm.pbf> directly.

openapi:
	./scripts/update-openapi.sh

# Flutter workspace (Melos). Flutter/Dart CLIs are broken natively in WSL
# (CRLF shell scripts), so these run through the Windows interop. Requires
# the melos.bat global activation path below.
MELOS ?= C:\Users\Ricardo\AppData\Local\Pub\Cache\bin\melos.bat

flutter-bootstrap:
	export FLUTTER_ROOT='I:\flutter'; cmd.exe /c "$(MELOS) bootstrap" | tr -d '\r'

flutter-analyze:
	export FLUTTER_ROOT='I:\flutter'; cmd.exe /c "$(MELOS) run analyze" | tr -d '\r'

flutter-test:
	export FLUTTER_ROOT='I:\flutter'; cmd.exe /c "$(MELOS) run test" | tr -d '\r'
