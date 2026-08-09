#!/usr/bin/env bash
# Shared helpers for the Immich Niro harness scripts.
# Sourced by start.sh / stop.sh / seed.sh / reset.sh — not run directly.

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
RUN_DIR="${HARNESS_DIR}/run"

COMPOSE_PROJECT="immich-niro"
COMPOSE=(docker compose -p "${COMPOSE_PROJECT}" -f "${HARNESS_DIR}/docker-compose.yml")

HOST="localhost"
PORT="2283"
BASE_URL="http://${HOST}:${PORT}"
API="${BASE_URL}/api"

# Deterministic seed identities. Fixed on purpose: the harness must produce
# the same baseline on every run (see harness README "Reproducible").
ADMIN_EMAIL="admin@niro.immich.test"
ADMIN_PASSWORD="NiroAdmin1234"
ADMIN_NAME="Niro Admin"

USER_A_EMAIL="user-a@niro.immich.test"
USER_A_PASSWORD="NiroUserA1234"
USER_A_NAME="Niro User A"

USER_B_EMAIL="user-b@niro.immich.test"
USER_B_PASSWORD="NiroUserB1234"
USER_B_NAME="Niro User B"

log() {
  echo "[harness] $*" >&2
}

wait_for_ping() {
  local timeout_seconds="${1:-600}"
  local waited=0
  log "Waiting for ${API}/server/ping (timeout ${timeout_seconds}s)..."
  while true; do
    if response="$(curl -fsS -m 3 "${API}/server/ping" 2>/dev/null)" && [[ "${response}" == '{"res":"pong"}' ]]; then
      log "Server is up."
      return 0
    fi
    if (( waited >= timeout_seconds )); then
      log "Timed out waiting for the server to become healthy."
      return 1
    fi
    sleep 3
    waited=$((waited + 3))
  done
}

# login <email> <password> -> prints accessToken on stdout, empty on failure
login() {
  local email="$1" password="$2"
  api_call POST /auth/login "$(jq -nc --arg email "$email" --arg password "$password" '{email:$email,password:$password}')"
  if [[ "${RESP_STATUS}" == "201" || "${RESP_STATUS}" == "200" ]]; then
    echo "${RESP_BODY}" | jq -r '.accessToken'
  else
    echo ""
  fi
}

# api_call <METHOD> <path> [json-body] [bearer-token]
# Sets RESP_STATUS and RESP_BODY. Never raises on non-2xx (caller checks).
api_call() {
  local method="$1" path="$2" data="${3:-}" token="${4:-}"
  local tmp
  tmp="$(mktemp)"
  local args=(-sS -m 30 -o "${tmp}" -w '%{http_code}' -X "${method}" "${API}${path}" -H 'Content-Type: application/json')
  if [[ -n "${token}" ]]; then
    args+=(-H "Authorization: Bearer ${token}")
  fi
  if [[ -n "${data}" ]]; then
    args+=(-d "${data}")
  fi
  RESP_STATUS="$(curl "${args[@]}")"
  RESP_BODY="$(cat "${tmp}")"
  rm -f "${tmp}"
}
