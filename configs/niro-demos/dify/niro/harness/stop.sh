#!/usr/bin/env bash
# Niro harness: stop the Dify stack cleanly. Containers and networks are
# removed; bind-mounted data under docker/volumes/ is left in place (use
# reset.sh for a clean data baseline).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"
PROJECT_NAME="dify-niro"

COMPOSE_ARGS=(
  -p "${PROJECT_NAME}"
  -f "${DOCKER_DIR}/docker-compose.yaml"
  -f "${SCRIPT_DIR}/docker-compose.override.yaml"
)
[[ -f "${ENV_FILE}" ]] && COMPOSE_ARGS+=(--env-file "${ENV_FILE}")

echo "[stop] stopping the dify-niro stack" >&2
docker compose "${COMPOSE_ARGS[@]}" down --remove-orphans
