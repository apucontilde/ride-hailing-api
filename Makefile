.PHONY: all build run test test-integration lint clean docker-up docker-down migrate-up migrate-down seed import-osm download-osm export-places openapi

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

download-osm:
	./scripts/download-osm.sh

export-places:
	./scripts/export-places.sh

openapi:
	./scripts/update-openapi.sh
