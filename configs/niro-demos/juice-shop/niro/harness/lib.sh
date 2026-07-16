#!/usr/bin/env bash
# Shared helpers for the OWASP Juice Shop Niro harness (start.sh / stop.sh /
# seed.sh / reset.sh). Not a lifecycle entry point itself.
set -euo pipefail

# Resolve paths relative to this file so scripts work regardless of caller cwd.
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
NIRO_DIR="$REPO_ROOT/niro"
RUN_DIR="$HARNESS_DIR/run"
PID_FILE="$RUN_DIR/juiceshop.pid"
LOG_FILE="$RUN_DIR/server.log"
BUILD_STAMP="$RUN_DIR/.build-stamp"

PORT="${NIRO_JUICESHOP_PORT:-3000}"
BASE_URL="http://127.0.0.1:${PORT}"

mkdir -p "$RUN_DIR"

log() { echo "[juice-shop-harness] $*" >&2; }

# True (0) if a server we started is alive and answering.
is_running() {
  if [ ! -f "$PID_FILE" ]; then
    return 1
  fi
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  curl -s -o /dev/null -m 3 "$BASE_URL/rest/admin/application-version" 2>/dev/null
}

# Wait up to $1 seconds (default 90) for the app to answer healthily.
wait_healthy() {
  local timeout="${1:-90}"
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if curl -s -o /dev/null -w '%{http_code}' -m 3 "$BASE_URL/rest/admin/application-version" 2>/dev/null | grep -q '^200$'; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# True (0) if the working tree looks newer than the last successful build.
needs_build() {
  if [ ! -f "$BUILD_STAMP" ]; then
    return 0
  fi
  if [ ! -f "$REPO_ROOT/build/app.js" ] || [ ! -f "$REPO_ROOT/frontend/dist/frontend/index.html" ]; then
    return 0
  fi
  # Check only the paths that actually feed `npm run build` (build:frontend +
  # build:server) — an allowlist, not a denylist. The app itself rewrites
  # plenty of paths at every startup (data/juiceshop.sqlite, i18n/*.json,
  # logs/, ftp/legal.md, .well-known/csaf/...) that are NOT build inputs;
  # scanning the whole repo and trying to prune around those is fragile and
  # was observed to trigger a spurious rebuild on every reset.
  local -a source_paths=(
    "$REPO_ROOT/app.ts"
    "$REPO_ROOT/server.ts"
    "$REPO_ROOT/package.json"
    "$REPO_ROOT/package-lock.json"
    "$REPO_ROOT/tsconfig.json"
    "$REPO_ROOT/routes"
    "$REPO_ROOT/models"
    "$REPO_ROOT/lib"
    "$REPO_ROOT/views"
    "$REPO_ROOT/data/datacreator.ts"
    "$REPO_ROOT/data/datacache.ts"
    "$REPO_ROOT/data/mongodb.ts"
    "$REPO_ROOT/data/staticData.ts"
    "$REPO_ROOT/data/types.ts"
    "$REPO_ROOT/frontend/src"
    "$REPO_ROOT/frontend/package.json"
    "$REPO_ROOT/frontend/package-lock.json"
    "$REPO_ROOT/frontend/angular.json"
  )
  local p newer
  for p in "${source_paths[@]}"; do
    [ -e "$p" ] || continue
    newer="$(find "$p" -newer "$BUILD_STAMP" -type f -print -quit)"
    if [ -n "$newer" ]; then
      return 0
    fi
  done
  return 1
}

build_app() {
  log "installing/building (npm install; runs postinstall: frontend install+build, server build)"
  (cd "$REPO_ROOT" && npm install --no-audit --no-fund) >>"$LOG_FILE.build" 2>&1
  date > "$BUILD_STAMP"
  log "build complete"
}

start_app() {
  if is_running; then
    log "already running at $BASE_URL"
    return 0
  fi
  # Clear any stale pid file left by a crashed process.
  rm -f "$PID_FILE"

  if needs_build; then
    build_app
  else
    log "build up to date, skipping install/build"
  fi

  log "starting server on port $PORT"
  (
    cd "$REPO_ROOT"
    # NODE_ENV is intentionally left unset: Juice Shop's config loader
    # (node-config) only overlays a file named after NODE_ENV, and this repo
    # ships no config/production.yml, so leaving it unset uses config/default.yml
    # as intended and avoids a spurious "did not match any deployment config"
    # warning.
    if command -v setsid >/dev/null 2>&1; then
      setsid env PORT="$PORT" node build/app.js </dev/null >>"$LOG_FILE" 2>&1 &
    else
      nohup env PORT="$PORT" node build/app.js </dev/null >>"$LOG_FILE" 2>&1 &
    fi
    echo $! > "$PID_FILE"
  )

  if ! wait_healthy 120; then
    log "server did not become healthy within timeout; last log lines:"
    tail -n 40 "$LOG_FILE" >&2 || true
    return 1
  fi
  log "server is healthy at $BASE_URL"
}

stop_app() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "stopping server (pid $pid)"
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
      done
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
  else
    log "no pid file, nothing to stop"
  fi
}
