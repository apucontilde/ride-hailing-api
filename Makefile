.PHONY: all build run test test-integration lint clean docker-up docker-down migrate-up migrate-down seed import-osm download-osm export-places openapi flutter-bootstrap flutter-analyze flutter-test

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
	go test -v -count=1 -tags=integration ./tests/...

lint:
	golangci-lint run ./...

clean:
	rm -rf $(BUILD_DIR)

seed:
	psql "$(DATABASE_URL)" -f scripts/seed.sql

import-osm:
	./scripts/import-road-network.sh

import-osm-force:
	./scripts/import-road-network.sh --force

download-osm:
	./scripts/download-osm.sh

export-places:
	./scripts/export-places.sh

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
