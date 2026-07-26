#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_ROOT="$(cd "${NIRO_DIR}/.." && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"
PORT="${NIRO_CASDOOR_PORT:-18000}"
MYSQL_PORT="${NIRO_MYSQL_PORT:-13306}"
COMPOSE_PROJECT_NAME="${NIRO_COMPOSE_PROJECT_NAME:-niro_casdoor}"
OVERRIDE_FILE="${RUN_DIR}/compose.override.yml"

mkdir -p "${RUN_DIR}/mysql"

cat > "${OVERRIDE_FILE}" <<EOF
services:
  casdoor:
    restart: unless-stopped
    ports: !override
      - "0.0.0.0:${PORT}:8000"
    environment:
      RUNNING_IN_DOCKER: "false"
      dataSourceName: "root:123456@tcp(db:3306)/"
    depends_on:
      - db
  db:
    restart: unless-stopped
    ports: !override
      - "127.0.0.1:${MYSQL_PORT}:3306"
    volumes:
      - "${RUN_DIR}/mysql:/var/lib/mysql"
EOF

cd "${PROJECT_ROOT}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" up -d --build

for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null; then
    echo "Casdoor is ready at http://127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 2
done

echo "Casdoor did not become healthy at http://127.0.0.1:${PORT}" >&2
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" logs --tail=200 >&2 || true
exit 1
