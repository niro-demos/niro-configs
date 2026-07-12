#!/usr/bin/env bash
# Build and start the full Dify stack from the current checkout: middleware
# via docker compose (postgres, redis, weaviate, sandbox, ssrf_proxy,
# plugin_daemon -- the project's own e2e middleware profile), then the
# backend API + Celery worker from source, then the frontend production
# build. Idempotent: safe to re-run, only (re)starts what isn't already up.
#
# See ../README.md for the harness interface contract this implements, and
# e2e/AGENTS.md for the underlying dev lifecycle this reuses.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=support/common.sh
source ./support/common.sh

require_cmd docker
require_cmd pnpm
require_cmd uv
require_cmd curl

log "Repo root: $ROOT_DIR"

# --- Dependencies -----------------------------------------------------
# Installing the JS workspace and syncing the Python project are both cheap
# no-ops when already up to date, and required the first time this harness
# runs in a fresh checkout/CI runner.
if [ ! -d "$ROOT_DIR/node_modules" ] || [ ! -d "$E2E_DIR/node_modules" ]; then
  log "Installing JS workspace dependencies (pnpm install)..."
  (cd "$ROOT_DIR" && pnpm install --frozen-lockfile)
else
  log "JS workspace dependencies already installed."
fi

log "Syncing Python dependencies for api/ (uv sync)..."
uv sync --project "$API_DIR" >"$LOG_DIR/uv-sync.log" 2>&1 || {
  log "uv sync failed; see $LOG_DIR/uv-sync.log"
  tail -n 80 "$LOG_DIR/uv-sync.log" >&2 || true
  exit 1
}

# --- Middleware (docker) ----------------------------------------------
# postgres, redis, weaviate, sandbox, ssrf_proxy, plugin_daemon -- pulled,
# published infrastructure images, not application code under test. This is
# the same profile e2e/scripts/setup.ts middleware-up uses for the project's
# own end-to-end suite.
log "Starting middleware (postgres, redis, weaviate, sandbox, ssrf_proxy, plugin_daemon)..."
e2e_tsx ./scripts/setup.ts middleware-up

# --- Backend API (built from source) -----------------------------------
# scripts/setup.ts api runs `flask upgrade-db` then `flask run`, both against
# api/ as checked out -- not a prebuilt image. Absolute script path so the
# backgrounded process resolves correctly regardless of pnpm's own cwd
# handling.
SETUP_TS="$E2E_DIR/scripts/setup.ts"
log "Starting API (flask upgrade-db + flask run, from api/ source)..."
start_component api "$API_URL/health" 420 -- \
  pnpm --dir "$E2E_DIR" exec tsx "$SETUP_TS" api

log "Starting Celery worker (dataset, priority_dataset, workflow_based_app_execution queues)..."
start_component celery "" 30 -- \
  pnpm --dir "$E2E_DIR" exec tsx "$SETUP_TS" celery --queues dataset,priority_dataset,workflow_based_app_execution

# --- Frontend (production build from source) ----------------------------
# scripts/setup.ts web builds the current web/ checkout (pnpm run build,
# reused if the source hash is unchanged) and serves it with `pnpm run
# start`, not a published image.
log "Building and starting web (this can take several minutes on a cold cache)..."
start_component web "$WEB_URL" 1200 -- \
  pnpm --dir "$E2E_DIR" exec tsx "$SETUP_TS" web

log ""
log "Dify is up:"
log "  Web (pentest base URL): $WEB_URL"
log "  API:                    $API_URL"
log ""
log "Run ./seed.sh next to create tenants, accounts, and fixtures."
