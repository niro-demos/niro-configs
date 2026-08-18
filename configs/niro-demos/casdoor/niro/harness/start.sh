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

mkdir -p "${RUN_DIR}/mysql" "${RUN_DIR}/storage" "${RUN_DIR}/webhook"
docker run --rm -v "${RUN_DIR}/storage:/storage" alpine:latest chown -R 1000:1000 /storage

cat > "${OVERRIDE_FILE}" <<EOF
services:
  casdoor:
    restart: unless-stopped
    build:
      context: ${PROJECT_ROOT}
      dockerfile: niro/harness/Dockerfile.niro
      target: STANDARD
    ports: !override
      - "0.0.0.0:${PORT}:8000"
    environment:
      RUNNING_IN_DOCKER: "false"
      dataSourceName: "root:123456@tcp(db:3306)/"
    depends_on:
      - db
      - webhook-receiver
    volumes:
      - "${RUN_DIR}/storage:/files"
  db:
    restart: unless-stopped
    ports: !override
      - "127.0.0.1:${MYSQL_PORT}:3306"
    volumes:
      - "${RUN_DIR}/mysql:/var/lib/mysql"
  webhook-receiver:
    restart: unless-stopped
    image: python:3.12-alpine
    command: ["python3", "/app/webhook_receiver.py"]
    volumes:
      - "${SCRIPT_DIR}/webhook_receiver.py:/app/webhook_receiver.py:ro"
      - "${RUN_DIR}/webhook:/run/webhook"
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "-", "http://127.0.0.1:19080/health"]
      interval: 2s
      timeout: 2s
      retries: 30
EOF

cd "${PROJECT_ROOT}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" up -d --build

for _ in $(seq 1 120); do
  receiver_status="$(COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" ps --format json webhook-receiver 2>/dev/null || true)"
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null && printf '%s' "${receiver_status}" | grep -q 'healthy'; then
    echo "Casdoor is ready at http://127.0.0.1:${PORT}"
    exit 0
  fi
  sleep 2
done

echo "Casdoor did not become healthy at http://127.0.0.1:${PORT}" >&2
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}" docker compose -f docker-compose.yml -f "${OVERRIDE_FILE}" logs --tail=200 >&2 || true
exit 1
