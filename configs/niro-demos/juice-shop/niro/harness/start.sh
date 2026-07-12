#!/usr/bin/env bash
# Build the current checkout (if needed) and start OWASP Juice Shop on
# localhost:3000, then wait for it to report healthy.
#
# Niro-managed runtime contract (see niro/harness/README.md):
#   - Build the current checkout, start the full service graph, verify
#     every tested surface is healthy.
#   - All mutable state (installed deps, build output, logs, pid file)
#     lives under niro/harness/run/, which is gitignored.
#
# Idempotent: re-running while the app is already up is a no-op.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HARNESS_DIR}/../.." && pwd)"
RUN_DIR="${HARNESS_DIR}/run"
PID_FILE="${RUN_DIR}/server.pid"
LOG_FILE="${RUN_DIR}/server.log"
PORT="${PORT:-3000}"
BASE_URL="http://localhost:${PORT}"

mkdir -p "${RUN_DIR}"
cd "${ROOT_DIR}"

# Already running and healthy? Nothing to do.
if [[ -f "${PID_FILE}" ]] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
  if curl -sf -o /dev/null "${BASE_URL}/rest/admin/application-version"; then
    echo "[start] already running (pid $(cat "${PID_FILE}")) and healthy at ${BASE_URL}"
    exit 0
  fi
  echo "[start] stale process $(cat "${PID_FILE}") is not healthy; restarting" >&2
  kill "$(cat "${PID_FILE}")" 2>/dev/null || true
  sleep 1
fi

# Install dependencies serving the CURRENT checkout. The repo intentionally
# gitignores package-lock.json, so `npm install` (not `npm ci`) is the
# supported path here. `postinstall` builds the Angular frontend
# automatically; we still run build:server explicitly below to guarantee a
# fresh TypeScript build of the current source (never a stale build/ dir).
if [[ ! -d "${ROOT_DIR}/node_modules" ]] || [[ ! -d "${ROOT_DIR}/frontend/node_modules" ]]; then
  echo "[start] installing dependencies (npm install; builds frontend via postinstall)..." >&2
  npm install >> "${LOG_FILE}.install" 2>&1
fi

# Always rebuild the server bundle from current source so a stale build/
# never serves outdated code. The frontend bundle from postinstall already
# reflects the checkout; rebuilding it too would just cost time for no
# behavior change, so only build:server here (cheap, ~seconds).
echo "[start] building server (npm run build:server)..." >&2
npm run build:server >> "${LOG_FILE}.install" 2>&1

if [[ ! -f "${ROOT_DIR}/frontend/dist/frontend/index.html" ]]; then
  echo "[start] frontend build missing; building it too..." >&2
  npm run build:frontend >> "${LOG_FILE}.install" 2>&1
fi

echo "[start] starting server on port ${PORT}..." >&2
PORT="${PORT}" nohup node build/app.js > "${LOG_FILE}" 2>&1 &
echo $! > "${PID_FILE}"

for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "${BASE_URL}/rest/admin/application-version"; then
    echo "[start] healthy at ${BASE_URL} (pid $(cat "${PID_FILE}"))"
    exit 0
  fi
  if ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "[start] server process died during startup; see ${LOG_FILE}" >&2
    tail -n 100 "${LOG_FILE}" >&2 || true
    exit 1
  fi
  sleep 1
done

echo "[start] server did not become healthy within 60s; see ${LOG_FILE}" >&2
tail -n 100 "${LOG_FILE}" >&2 || true
exit 1
