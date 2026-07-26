#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${NIRO_DIR}/.." && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"
COMPOSE_PROJECT_NAME="${NIRO_COMPOSE_PROJECT_NAME:-niro_casdoor}"
OVERRIDE_FILE="${RUN_DIR}/compose.override.yml"

cd "${PROJECT_ROOT}"
if [[ -f "${OVERRIDE_FILE}" ]]; then
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" down
else
  COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml down
fi
