#!/usr/bin/env bash
# Build the current Casdoor checkout and start it as a background process.
# Niro-managed runtime: no external DB service — uses the app's own sqlite
# driver (modernc.org/sqlite, already in go.mod) so there is nothing extra to
# provision. Idempotent: a second call is a no-op if the server is already
# healthy.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HARNESS_DIR/lib.sh"

if server_pid >/dev/null 2>&1 && is_healthy; then
  echo "[start] casdoor already running and healthy at $BASE_URL (pid $(server_pid))"
  exit 0
fi

# A pidfile with a dead pid, or a live pid that isn't answering health checks
# yet, both fall through to a fresh start below.
if server_pid >/dev/null 2>&1; then
  echo "[start] existing process (pid $(server_pid)) is not healthy, stopping it first"
  "$HARNESS_DIR/stop.sh" || true
fi

build_backend
build_frontend_if_stale
prepare_serve_dir

echo "[start] launching server on $BASE_URL (cwd=$SERVE_DIR, db=$DB_FILE)"

# Every key below is read via conf.GetConfigString(key), which checks the
# process environment before falling back to conf/app.conf — so this fully
# overrides the tracked app.conf without editing it.
LOG_CONFIG_JSON=$(printf '{"adapter":"file","filename":"%s","maxdays":99999,"perm":"0770"}' "$SERVER_LOG")

(
  cd "$SERVE_DIR"
  env \
    appname=casdoor \
    httpport="$HTTP_PORT" \
    runmode=dev \
    driverName=sqlite \
    dataSourceName="file:${DB_FILE}?cache=shared" \
    dbName=casdoor \
    initDataFile="$INIT_DATA_SEED" \
    initDataNewOnly=false \
    logConfig="$LOG_CONFIG_JSON" \
    frontendBaseDir="$REPO_ROOT/web/build" \
    origin="$BASE_URL" \
    originFrontend="$BASE_URL" \
    RUNNING_IN_DOCKER=false \
    ldapServerPort="$LDAP_PORT" \
    ldapsServerPort="$LDAPS_PORT" \
    ldapsCertId="admin/cert-built-in" \
    nohup "$SERVER_BIN" \
    > "$RUN_DIR/server-stdout.log" 2>&1 &
  echo $! > "$PID_FILE"
)

echo "[start] waiting for $BASE_URL/api/health ..."
if ! wait_for_health 120; then
  echo "[start] FAILED: server did not become healthy in time. Last 80 lines of log:" >&2
  tail -n 80 "$RUN_DIR/server-stdout.log" >&2 || true
  exit 1
fi

echo "[start] casdoor is up at $BASE_URL (pid $(cat "$PID_FILE"))"
