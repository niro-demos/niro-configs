#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${NIRO_DIR}/.." && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"
DATA_DIR="${RUN_DIR}/data"
LOG_DIR="${RUN_DIR}/logs"
PID_FILE="${RUN_DIR}/vaultwarden.pid"
ENV_FILE="${RUN_DIR}/env"
DB_FILE="${DATA_DIR}/db.sqlite3"
TARGET_HOST="localhost"
LISTEN_ADDRESS="0.0.0.0"
TARGET_PORT="8123"
TARGET_URL="http://${TARGET_HOST}:${TARGET_PORT}"
ADMIN_TOKEN_VALUE="niro-local-admin-token-2026"

mkdir -p "${RUN_DIR}" "${DATA_DIR}" "${LOG_DIR}"

export DATA_FOLDER="${DATA_DIR}"
export DATABASE_URL="sqlite://${DB_FILE}"
export DOMAIN="${TARGET_URL}"
export ROCKET_ADDRESS="${LISTEN_ADDRESS}"
export ROCKET_PORT="${TARGET_PORT}"
export ROCKET_LOG_LEVEL="${ROCKET_LOG_LEVEL:-normal}"
export SIGNUPS_ALLOWED="false"
export INVITATIONS_ALLOWED="false"
export ORG_CREATION_USERS="none"
export ADMIN_TOKEN="${ADMIN_TOKEN_VALUE}"
export PASSWORD_ITERATIONS="100000"
export SENDS_ALLOWED="true"
export EMERGENCY_ACCESS_ALLOWED="true"
export WEB_VAULT_ENABLED="false"
export WEBSOCKET_ENABLED="true"
export LOGIN_RATELIMIT_SECONDS="1"
export LOGIN_RATELIMIT_MAX_BURST="100000"
export ADMIN_RATELIMIT_SECONDS="1"
export ADMIN_RATELIMIT_MAX_BURST="100000"
export UNAUTHENTICATED_RATELIMIT_SECONDS="1"
export UNAUTHENTICATED_RATELIMIT_MAX_BURST="100000"

write_runtime_env() {
  cat > "${ENV_FILE}" <<EOF
TARGET_URL=${TARGET_URL}
DATABASE_URL=${DATABASE_URL}
DATA_FOLDER=${DATA_FOLDER}
ADMIN_TOKEN=${ADMIN_TOKEN_VALUE}
EOF
}

is_running() {
  [[ -f "${PID_FILE}" ]] || return 1
  local pid
  pid="$(cat "${PID_FILE}")"
  [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null
}

wait_for_http() {
  local url="$1"
  local deadline=$((SECONDS + 60))
  until curl -fsS "${url}" >/dev/null 2>&1; do
    if [[ -f "${PID_FILE}" ]] && ! is_running; then
      echo "Vaultwarden process exited while waiting for ${url}" >&2
      tail -n 80 "${LOG_DIR}/vaultwarden.log" >&2 || true
      return 1
    fi
    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for ${url}" >&2
      tail -n 80 "${LOG_DIR}/vaultwarden.log" >&2 || true
      return 1
    fi
    sleep 1
  done
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required tool '$1' is not installed or not on PATH" >&2
    exit 1
  }
}
