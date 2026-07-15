#!/usr/bin/env bash
# Shared paths/helpers for the Casdoor Niro harness scripts.
# Sourced by start.sh / stop.sh / seed.sh / reset.sh — not meant to be run directly.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
RUN_DIR="$HARNESS_DIR/run"

BIN_DIR="$RUN_DIR/bin"
DATA_DIR="$RUN_DIR/data"
LOG_DIR="$RUN_DIR/logs"
SERVE_DIR="$RUN_DIR/serve"

SERVER_BIN="$BIN_DIR/server"
DB_FILE="$DATA_DIR/casdoor.db"
SERVER_LOG="$LOG_DIR/casdoor-server.log"
PID_FILE="$RUN_DIR/server.pid"
INIT_DATA_SEED="$HARNESS_DIR/init_data.seed.json"

HTTP_PORT="${CASDOOR_HTTP_PORT:-8000}"
BASE_URL="http://localhost:${HTTP_PORT}"
# app.conf's defaults (389/636) are privileged ports the harness process
# can't bind as a non-root user; conf.GetConfigString reads any key from the
# environment first, so remap to unprivileged ports here rather than editing
# the tracked conf/app.conf.
LDAP_PORT="${CASDOOR_LDAP_PORT:-1389}"
LDAPS_PORT="${CASDOOR_LDAPS_PORT:-1636}"

CREDENTIALS_FILE="$HARNESS_DIR/../credentials.yaml"
FIXTURES_FILE="$HARNESS_DIR/../fixtures.yaml"

# Plaintext test passwords — single source of truth, also embedded (identically)
# in init_data.seed.json. Kept here so seed.sh/reset.sh can render credentials.yaml
# without re-parsing JSON.
ADMIN_PASSWORD="123"
ALICE_PASSWORD="Alice-Test-Pw1!"
BOB_PASSWORD="Bob-Test-Pw1!"
ACME_ADMIN_PASSWORD="AcmeAdmin-Test-Pw1!"

mkdir -p "$BIN_DIR" "$DATA_DIR" "$LOG_DIR" "$SERVE_DIR"

server_pid() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  return 1
}

is_healthy() {
  curl -fsS -o /dev/null --max-time 2 "$BASE_URL/api/health" 2>/dev/null
}

wait_for_health() {
  local tries="${1:-90}"
  local i=0
  while [ "$i" -lt "$tries" ]; do
    if is_healthy; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# newest mtime (epoch seconds) under a directory, 0 if it doesn't exist
newest_mtime() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi
  find "$dir" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1 || echo 0
}

build_backend() {
  echo "[lib] building backend from current checkout..." >&2
  (cd "$REPO_ROOT" && go build -o "$SERVER_BIN" .)
}

build_frontend_if_stale() {
  local build_index="$REPO_ROOT/web/build/index.html"
  local src_mtime pkg_mtime build_mtime
  src_mtime="$(newest_mtime "$REPO_ROOT/web/src")"
  pkg_mtime="$(newest_mtime "$REPO_ROOT/web/public")"
  build_mtime=0
  if [ -f "$build_index" ]; then
    build_mtime="$(stat -c '%Y' "$build_index" 2>/dev/null || echo 0)"
  fi

  if [ -f "$build_index" ] && [ "$build_mtime" -ge "$src_mtime" ] && [ "$build_mtime" -ge "$pkg_mtime" ] && [ "${FORCE_REBUILD_FRONTEND:-0}" != "1" ]; then
    echo "[lib] frontend build is up to date, skipping rebuild" >&2
    return 0
  fi

  echo "[lib] building frontend from current checkout (this can take several minutes)..." >&2
  (
    cd "$REPO_ROOT/web"
    export NODE_OPTIONS="--max-old-space-size=4096"
    yarn install --frozen-lockfile --network-timeout 1000000
    CI=false yarn run build
  )
}

prepare_serve_dir() {
  ln -sfn "$REPO_ROOT/conf" "$SERVE_DIR/conf"
  ln -sfn "$REPO_ROOT/swagger" "$SERVE_DIR/swagger"
  mkdir -p "$SERVE_DIR/files" "$SERVE_DIR/tmp"
}
