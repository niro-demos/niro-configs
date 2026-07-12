#!/usr/bin/env bash
# Shared paths and helpers for the Dify Niro harness (macOS/Linux).
#
# Every harness/*.sh script sources this file first. It resolves repo-relative
# paths from this file's own location so the scripts work regardless of the
# caller's current working directory, defines the fixed local ports the
# harness always uses, and provides small process/http helpers used by
# start.sh, stop.sh, seed.sh, and reset.sh.

set -uo pipefail

HARNESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT_DIR
ROOT_DIR="$(cd "$HARNESS_LIB_DIR/../../.." && pwd)"
export NIRO_DIR="$ROOT_DIR/niro"
export HARNESS_DIR="$NIRO_DIR/harness"
export RUN_DIR="$HARNESS_DIR/run"
export LOG_DIR="$RUN_DIR/logs"
export PID_DIR="$RUN_DIR/pids"
export COOKIE_DIR="$RUN_DIR/cookies"
export STATE_DIR="$RUN_DIR/state"
export E2E_DIR="$ROOT_DIR/e2e"
export API_DIR="$ROOT_DIR/api"
export WEB_DIR="$ROOT_DIR/web"
export DOCKER_DIR="$ROOT_DIR/docker"
export FIXTURES_DIR="$HARNESS_DIR/fixtures"

# The API env file the project's own E2E suite uses to run the Flask app from
# source against the docker-compose.middleware.yaml services. Reused here so
# the harness matches an already-committed, already-tested configuration
# instead of inventing a parallel one.
export API_ENV_FILE="$API_DIR/tests/integration_tests/.env.example"

export API_HOST="127.0.0.1"
export API_PORT="5001"
export WEB_HOST="127.0.0.1"
export WEB_PORT="3000"
export API_URL="http://${API_HOST}:${API_PORT}"
export WEB_URL="http://${WEB_HOST}:${WEB_PORT}"

# The /openapi/v1/* blueprint (api/extensions/ext_blueprints.py) is only
# registered when dify_config.OPENAPI_ENABLED is true, and it defaults to
# false (api/configs/feature/__init__.py). e2e/scripts/setup.ts's
# runForegroundProcess (e2e/scripts/common.ts) spreads `...process.env`
# before its own overrides, so exporting this here -- rather than editing
# the shared api/tests/integration_tests/.env.example -- is enough to turn
# the blueprint on for the harness's API process without touching real
# integration-test config. Left overridable so a caller can still force it
# off.
export OPENAPI_ENABLED="${OPENAPI_ENABLED:-true}"

mkdir -p "$LOG_DIR" "$PID_DIR" "$COOKIE_DIR" "$STATE_DIR"

log() {
  printf '[harness] %s\n' "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

# wait_for_http <url> [timeout_seconds]
wait_for_http() {
  local url="$1" timeout_s="${2:-120}" waited=0
  until curl -fsS -o /dev/null "$url" 2>/dev/null; do
    sleep 2
    waited=$((waited + 2))
    if [ "$waited" -ge "$timeout_s" ]; then
      log "Timed out after ${timeout_s}s waiting for $url"
      return 1
    fi
  done
}

pid_running() {
  local pid="${1:-}"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

component_pid() {
  local pidfile="$PID_DIR/${1}.pid"
  # Always exits 0 (pidfile absent just means "not started yet") so callers
  # doing `var="$(component_pid name)"` under `set -e` don't abort the
  # whole script when nothing is running yet.
  if [ -f "$pidfile" ]; then
    cat "$pidfile"
  fi
  return 0
}

# start_background <name> -- <command...>
# Spawns a detached, logged background process and records its pid.
start_background() {
  local name="$1"
  shift
  [ "${1:-}" = "--" ] && shift
  nohup "$@" >"$LOG_DIR/${name}.log" 2>&1 </dev/null &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  echo "$pid" >"$PID_DIR/${name}.pid"
  log "Started $name (pid $pid) -> $LOG_DIR/${name}.log"
}

# stop_background <name>
# Sends SIGTERM (then SIGKILL if needed) to a process started with
# start_background. Relies on the target process (a Node/tsx wrapper around
# the real server, see scripts/setup.ts) forwarding the signal to its own
# child, which is how e2e/support/process.ts's equivalents behave too.
stop_background() {
  local name="$1"
  local pidfile="$PID_DIR/${name}.pid"
  [ -f "$pidfile" ] || return 0
  local pid
  pid="$(cat "$pidfile")"
  if pid_running "$pid"; then
    log "Stopping $name (pid $pid)"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      pid_running "$pid" || break
      sleep 1
    done
    if pid_running "$pid"; then
      log "Force killing $name (pid $pid)"
      pkill -KILL -P "$pid" 2>/dev/null || true
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  rm -f "$pidfile"
}

# start_component <name> <healthcheck_url|""> <timeout_seconds> -- <command...>
# Idempotent: if the healthcheck already passes (http case) or the pidfile
# points at a live process (non-http case, e.g. celery), does nothing.
start_component() {
  local name="$1" healthcheck_url="$2" timeout_s="$3"
  shift 3
  [ "${1:-}" = "--" ] && shift

  if [ -n "$healthcheck_url" ]; then
    if curl -fsS -o /dev/null "$healthcheck_url" 2>/dev/null; then
      log "$name already responding at $healthcheck_url"
      return 0
    fi
  else
    local existing
    existing="$(component_pid "$name")"
    if pid_running "$existing"; then
      log "$name already running (pid $existing)"
      return 0
    fi
  fi

  start_background "$name" -- "$@"

  if [ -n "$healthcheck_url" ]; then
    wait_for_http "$healthcheck_url" "$timeout_s" || {
      log "$name did not become healthy; tail of $LOG_DIR/${name}.log:"
      tail -n 80 "$LOG_DIR/${name}.log" >&2 || true
      return 1
    }
  else
    sleep 3
    pid_running "$(component_pid "$name")" || {
      log "$name exited immediately; tail of $LOG_DIR/${name}.log:"
      tail -n 80 "$LOG_DIR/${name}.log" >&2 || true
      return 1
    }
  fi
}

e2e_tsx() {
  pnpm --dir "$E2E_DIR" exec tsx "$@"
}

# flask_cli <flask subcommand and args...>
# Runs a Flask CLI command against the API's own source tree, using the same
# env file (api/tests/integration_tests/.env.example) the running API and
# e2e suite use, so it talks to the same Postgres/Redis started by
# middleware-up. This is the project's own sanctioned tooling for creating
# tenants and resetting passwords (see api/commands/account.py) rather than
# a bespoke DB-writing shortcut.
flask_cli() {
  # `uv run --project` picks the venv/lockfile but does NOT change the
  # spawned process's cwd -- Flask resolves FLASK_APP=app.py relative to
  # cwd, so this must actually run from api/ (matching how
  # e2e/scripts/setup.ts spawns `uv run` with cwd: apiDir).
  ( cd "$API_DIR" && FLASK_APP=app.py uv run --project . --env-file "$API_ENV_FILE" flask "$@" )
}
