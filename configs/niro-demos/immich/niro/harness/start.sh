#!/usr/bin/env bash
# Build the current checkout and start the full Immich service graph
# (server + Postgres + Redis) under Docker Compose. Idempotent: re-running
# reuses build cache / already-running containers.
#
# Does NOT touch the host docker context/DOCKER_HOST/XDG_CACHE_HOME — only
# invokes `docker compose` against niro/harness/docker-compose.yml, which
# builds the app's own server/Dockerfile from the current checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

mkdir -p "${RUN_DIR}/library" "${RUN_DIR}/postgres"

log "Building and starting Immich from the current checkout (docker compose project: ${COMPOSE_PROJECT})..."
"${COMPOSE[@]}" up -d --build --remove-orphans

if ! wait_for_ping 900; then
  log "immich-server did not become healthy in time. Recent logs:"
  "${COMPOSE[@]}" logs --tail=200 immich-server >&2 || true
  exit 1
fi

log "Immich is up at ${BASE_URL}"
