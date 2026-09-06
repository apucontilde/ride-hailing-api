#!/usr/bin/env bash
# Regenerates the OpenAPI spec from the Go annotations in the codebase.
#
# Uses swaggo/swag to parse the swagger annotations and Go types, then runs
# cmd/openapi to reconcile the output against the routes actually registered
# in the router so the spec always matches the code.
#
# Output:
#   docs/swagger.json
#   docs/swagger.yaml
#
# Override the pinned swag version with SWAG_VERSION if needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SWAG_VERSION="${SWAG_VERSION:-v1.16.4}"
DOCS_DIR="docs"

# Locate the Go toolchain (handles plain `go` on Linux/macOS/git-bash and
# `go.exe` under WSL, where extensionless PATH lookup does not match .exe).
GO_BIN=""
for candidate in go go.exe; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    GO_BIN="${candidate}"
    break
  fi
done
if [[ -z "${GO_BIN}" ]]; then
  echo "error: go not found in PATH" >&2
  exit 1
fi

# Locate swag, installing it on first use.
SWAG_BIN=""
for candidate in swag swag.exe; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    SWAG_BIN="${candidate}"
    break
  fi
done
if [[ -z "${SWAG_BIN}" ]]; then
  echo "swag not found; installing ${SWAG_VERSION}..."
  "${GO_BIN}" install "github.com/swaggo/swag/cmd/swag@${SWAG_VERSION}"
  export PATH="${GOPATH:-$("${GO_BIN}" env GOPATH)}/bin:${PATH}"
  for candidate in swag swag.exe; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      SWAG_BIN="${candidate}"
      break
    fi
  done
fi
if [[ -z "${SWAG_BIN}" ]]; then
  echo "error: swag could not be found or installed" >&2
  exit 1
fi

echo "==> Formatting swagger annotations"
"${SWAG_BIN}" fmt -g cmd/server/main.go

echo "==> Generating spec from annotations"
"${SWAG_BIN}" init -g cmd/server/main.go --parseInternal --output "${DOCS_DIR}" --outputTypes json --quiet

echo "==> Syncing spec with registered routes"
"${GO_BIN}" run ./cmd/openapi "${DOCS_DIR}/swagger.json"

echo "==> Done"
echo "    ${DOCS_DIR}/swagger.json"
echo "    ${DOCS_DIR}/swagger.yaml"
