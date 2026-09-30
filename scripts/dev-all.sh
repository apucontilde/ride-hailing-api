#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# One command for the whole local stack, everything inside WSL:
#
#   1. docker compose up -d   -> PostGIS + Redis
#   2. make run                -> Go API on :8080 (waits for /health)
#   3. flutter run -d chrome   -> rider_app, then driver_app
#
# Flutter is the LINUX FVM SDK (~/fvm/default). The Windows SDK on
# I:\flutter cannot be executed from WSL (CRLF endings in bin/flutter),
# so it is never used here even when it comes first on PATH.
#
# The apps start SEQUENTIALLY, never in parallel: they share the
# workspace's root .dart_tool (package config + native-asset hooks),
# and a concurrent `flutter run` blocks on the exclusive
# .dart_tool/hooks_runner/**/.lock -- the 5-minute lock timeout you
# see in the apps' flutter_*.log files.
#
# Logs land in .tmp/dev/{api,rider,driver}.log and are streamed to this
# terminal at the same time. Ctrl-C stops every process this script
# started (docker containers are left up unless --stop-docker).
# ------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DEVICE="chrome"
PORT="8080"
DO_DOCKER=1
DO_BOOTSTRAP=1
DO_SERVER=1
APPS="rider_app driver_app"
STOP_DOCKER=0
READY_TIMEOUT=600

usage() {
  cat <<'EOF'
Usage: scripts/dev-all.sh [options]

Starts the local stack inside WSL: docker compose (PostGIS + Redis),
the Go API, and one `flutter run` per Flutter app.

Options:
  -d, --device <id>       Flutter device for the apps (default: chrome)
                          Other useful values: web-server, linux, windows
  -p, --port <n>          API port for make run and the apps (default: 8080)
      --no-docker         Do not touch docker compose (assume it is up)
      --no-server         Do not start the Go API
      --no-bootstrap      Do not run `melos bootstrap` first
      --no-rider          Do not start rider_app
      --no-driver         Do not start driver_app
      --stop-docker       On exit, also `docker compose down`
      --ready-timeout <s> Per-app build/attach timeout (default: 600)
  -h, --help              This text

Environment:
  FLUTTER_BIN             Override the Flutter executable
                          (default: $HOME/fvm/default/bin/flutter)

Examples:
  scripts/dev-all.sh                          # chrome, everything
  scripts/dev-all.sh -d web-server            # no browser, prints URLs
  scripts/dev-all.sh --no-server --no-driver  # rider app only
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device)        DEVICE="${2:?--device needs a value}"; shift 2 ;;
    -p|--port)          PORT="${2:?--port needs a value}"; shift 2 ;;
    --no-docker)        DO_DOCKER=0; shift ;;
    --no-server)        DO_SERVER=0; shift ;;
    --no-bootstrap)     DO_BOOTSTRAP=0; shift ;;
    --no-rider)         APPS="${APPS//rider_app/}"; shift ;;
    --no-driver)        APPS="${APPS//driver_app/}"; shift ;;
    --stop-docker)      STOP_DOCKER=1; shift ;;
    --ready-timeout)    READY_TIMEOUT="${2:?--ready-timeout needs a value}"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *)                  usage; die "unknown option: $1" ;;
  esac
done

LOG_DIR="$REPO_ROOT/.tmp/dev"
API_URL="http://localhost:$PORT"
mkdir -p "$LOG_DIR"

CHILD_PIDS=()
LOG_FILES=()

# ---------------------------------------------------------------- preflight
step "Preflight"

command -v go >/dev/null 2>&1 || die "go is not on PATH"
[ "$DO_SERVER" = 1 ] || command -v make >/dev/null 2>&1 || die "make is not on PATH"

FLUTTER=""
if [ -n "${FLUTTER_BIN:-}" ]; then
  FLUTTER="$FLUTTER_BIN"
elif [ -x "$HOME/fvm/default/bin/flutter" ]; then
  FLUTTER="$HOME/fvm/default/bin/flutter"
  export PATH="$HOME/fvm/default/bin:$PATH"
elif command -v flutter >/dev/null 2>&1 && flutter --version >/dev/null 2>&1; then
  FLUTTER="$(command -v flutter)"
fi
[ -n "$FLUTTER" ] || die "no working Flutter found. This script needs the LINUX SDK
  (default \$HOME/fvm/default/bin/flutter); the Windows SDK on I:\\flutter
  cannot run from WSL. Set FLUTTER_BIN to point at a Linux Flutter."
"$FLUTTER" --version >/dev/null 2>&1 \
  || die "'$FLUTTER' is not a working Linux Flutter (CRLF Windows SDK?). Set FLUTTER_BIN."
echo "    flutter: $FLUTTER ($("$FLUTTER" --version 2>/dev/null | head -1))"

if [ "$DO_DOCKER" = 1 ]; then
  command -v docker >/dev/null 2>&1 || die "docker is not on PATH (use --no-docker)"
  docker compose version >/dev/null 2>&1 || die "'docker compose' (v2) is required"
fi

for app in $APPS; do
  [ -d "$REPO_ROOT/$app" ] || die "missing app directory: $app"
done
[ "$DO_SERVER" = 1 ] || [ -n "$(echo $APPS)" ] \
  || die "--no-server together with --no-rider --no-driver starts nothing"

# ------------------------------------------------------------------ cleanup
# Setsid gives every child its own process group, so killing the group reaches
# the whole tree: `make run` -> go run -> server, and `flutter run -d chrome` ->
# dart tool -> chromium. No pattern matching needed (it would hit unrelated
# sessions).
cleanup() {
  trap - EXIT INT TERM
  local pid
  [ -n "${PUMP_PID:-}" ] && kill "$PUMP_PID" 2>/dev/null || true
  for pid in "${CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in "${CHILD_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  done
  if [ "$STOP_DOCKER" = 1 ] && [ "$DO_DOCKER" = 1 ]; then
    echo; echo "==> Stopping docker compose"
    docker compose down >/dev/null 2>&1 || true
  fi
  echo "==> Stopped. Logs kept in $LOG_DIR"
}
on_signal() { echo; cleanup; exit 130; }
trap cleanup EXIT
trap on_signal INT TERM

# start_bg <log-name> <label> <workdir> <command...>
start_bg() {
  local log="$LOG_DIR/$1.log" label="$2" dir="$3"; shift 3
  LOG_FILES+=("$log")
  # setsid => own process group, so cleanup can kill the whole tree
  # (go run -> server, flutter run -> dart + chromium).
  ( cd "$dir" && exec setsid "$@" ) >"$log" 2>&1 &
  CHILD_PIDS+=("$!")
  echo "    started $label (pid $!, log $(basename "$log"))"
}

# wait_for <label> <pid> <log> <regex> <timeout-seconds>
wait_for() {
  local label="$1" pid="$2" log="$3" regex="$4" timeout="$5" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "    $label exited before it was ready; last lines of $(basename "$log"):"
      tail -n 20 "$log" | sed "s/^/      /" >&2
      return 1
    fi
    if [ -f "$log" ] && grep -qE "$regex" "$log"; then
      return 0
    fi
    sleep 2; waited=$((waited + 2))
    [ $((waited % 20)) -eq 0 ] && echo "    waiting for $label... ${waited}s"
  done
  echo "    $label did not become ready within ${timeout}s; last lines:" >&2
  tail -n 20 "$log" | sed "s/^/      /" >&2
  return 1
}

# ------------------------------------------------------------------ docker
if [ "$DO_DOCKER" = 1 ]; then
  step "Starting PostGIS + Redis"
  docker compose up -d
  for container in ride-hailing-db ride-hailing-redis; do
    for _ in $(seq 1 60); do
      health="$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo starting)"
      [ "$health" = healthy ] && break
      sleep 2
    done
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo starting)" = healthy ] \
      || die "$container is not healthy (docker compose logs $container)"
    echo "    $container: healthy"
  done
fi

# --------------------------------------------------------------- workspace
if [ "$DO_BOOTSTRAP" = 1 ] && [ -n "$(echo $APPS)" ]; then
  step "Resolving workspace packages (melos bootstrap)"
  if command -v melos >/dev/null 2>&1; then
    melos bootstrap
  else
    echo "    melos not found, skipping (packages may be unresolved)"
  fi
fi

# ------------------------------------------------------------------ server
if [ "$DO_SERVER" = 1 ]; then
  step "Starting API on $API_URL"
  start_bg api "API (make run)" "$REPO_ROOT" make run
  api_pid="${CHILD_PIDS[-1]}"
  if command -v curl >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
      # /health/ready is 200 only once postgres AND redis answer.
      if curl -fsS -o /dev/null "http://127.0.0.1:$PORT/health/ready" 2>/dev/null; then
        echo "    API is ready (postgres + redis reachable)"
        break
      fi
      kill -0 "$api_pid" 2>/dev/null || die "API exited on startup; see $LOG_DIR/api.log"
      sleep 2
    done
    curl -fsS -o /dev/null "http://127.0.0.1:$PORT/health/ready" 2>/dev/null \
      || die "API did not become ready on :$PORT (is the port taken?); see $LOG_DIR/api.log"
  else
    sleep 3
    kill -0 "$api_pid" 2>/dev/null || die "API exited on startup; see $LOG_DIR/api.log"
  fi
fi

# -------------------------------------------------------------------- apps
step "Starting Flutter apps on '$DEVICE' (sequentially)"
for app in $APPS; do
  start_bg "$app" "$app" "$REPO_ROOT/$app" \
    "$FLUTTER" run -d "$DEVICE" --dart-define=API_BASE_URL="$API_URL"
  wait_for "$app" "${CHILD_PIDS[-1]}" "$LOG_DIR/$app.log" \
    "Debug service listening on|is being served on" "$READY_TIMEOUT" \
    || die "$app failed to start; see $LOG_DIR/$app.log"
  echo "    $app is attached (Ctrl-C here stops everything)"
done

# ------------------------------------------------------------------ monitor
step "Stack is up -- streaming logs, Ctrl-C to stop"

# The log pump is a plain background subshell (same process group, so Ctrl-C
# takes it down with everything else). It tails the per-child log files and
# re-prints new bytes with a "<component> | " prefix. The main shell below
# only ever blocks in `wait`, which is interruptible, so Ctrl-C reaches the
# trap handlers above instead of a command substitution.
(
  declare -A seen=()
  for log in "${LOG_FILES[@]}"; do seen[$log]=0; done
  while kill -0 "$PPID" 2>/dev/null; do
    for log in "${LOG_FILES[@]}"; do
      size=$(stat -c%s "$log" 2>/dev/null || echo 0)
      from="${seen[$log]}"
      if [ "$size" -lt "$from" ]; then from=0; fi   # log was truncated
      if [ "$size" -gt "$from" ]; then
        tail -c "+$((from + 1))" "$log" \
          | tr -d '\r' \
          | sed -r "s/\x1b\[[0-9;?]*[a-zA-Z]//g; s@^@$(basename "$log" .log) | @"
        seen[$log]="$size"
      fi
    done
    sleep 1
  done
) &
PUMP_PID=$!

# Block until one of the children exits (or a signal arrives, which runs the
# traps). Then report which one and stop the rest.
while true; do
  wait -n "${CHILD_PIDS[@]}" 2>/dev/null || true
  for i in "${!CHILD_PIDS[@]}"; do
    if ! kill -0 "${CHILD_PIDS[$i]}" 2>/dev/null; then
      echo; echo "==> $(basename "${LOG_FILES[$i]}" .log) exited; last lines:"
      tail -n 20 "${LOG_FILES[$i]}" | sed 's/^/      /'
      exit 1
    fi
  done
  sleep 0.5
done
