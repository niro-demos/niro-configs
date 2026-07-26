#!/usr/bin/env bash
# Niro harness: seed deterministic tenants/accounts/apps/datasets into the
# running Dify stack and (re)generate ../credentials.yaml and ../fixtures.yaml
# from the result.
#
# Idempotent: re-running against an already-seeded database reuses existing
# tenants/apps/datasets and resets seeded accounts' passwords to the known
# value, so credentials.yaml always matches the live database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NIRO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"
PROJECT_NAME="dify-niro"

COMPOSE_ARGS=(
  -p "${PROJECT_NAME}"
  -f "${DOCKER_DIR}/docker-compose.yaml"
  -f "${SCRIPT_DIR}/docker-compose.override.yaml"
  --env-file "${ENV_FILE}"
)

log() { echo "[seed] $*" >&2; }

if ! docker compose "${COMPOSE_ARGS[@]}" ps --status running --services 2>/dev/null | grep -qx api; then
  log "ERROR: the 'api' service is not running. Run niro/harness/start.sh first."
  exit 1
fi

# Copied into /app/api/ (not /tmp/) because Python puts the *script's own
# directory* on sys.path[0] when run as `python3 /path/to/script.py` -- it
# needs to sit next to app_factory.py etc. to import them, the same way the
# api service's own entrypoint (cwd=/app/api, Dockerfile WORKDIR) does.
log "copying seed_dify.py into the api container"
docker compose "${COMPOSE_ARGS[@]}" cp "${SCRIPT_DIR}/seed_dify.py" api:/app/api/niro_seed_dify.py

log "running seed_dify.py inside the api container"
SEED_JSON="$(docker compose "${COMPOSE_ARGS[@]}" exec -T api python3 /app/api/niro_seed_dify.py)"

log "rendering ${NIRO_DIR}/credentials.yaml and ${NIRO_DIR}/fixtures.yaml"
printf '%s' "${SEED_JSON}" | python3 "${SCRIPT_DIR}/render_niro_files.py" "${NIRO_DIR}"

log "done"
