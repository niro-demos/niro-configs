#!/usr/bin/env bash
# Build the current checkout's api + web images and start the full Dify
# service graph (postgres, redis, weaviate, sandbox, local_sandbox,
# plugin_daemon, agent_backend, ssrf_proxy, nginx, api, api_websocket,
# worker, worker_beat, web) via docker/docker-compose.yaml plus
# niro/harness/docker-compose.override.yaml. Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

echo "Repo root: ${NIRO_REPO_ROOT}"
mkdir -p \
  "${NIRO_RUN_DIR}/volumes/db/data" \
  "${NIRO_RUN_DIR}/volumes/redis/data" \
  "${NIRO_RUN_DIR}/volumes/app/storage" \
  "${NIRO_RUN_DIR}/volumes/sandbox/dependencies" \
  "${NIRO_RUN_DIR}/volumes/plugin_daemon" \
  "${NIRO_RUN_DIR}/volumes/weaviate"

ensure_secrets
ensure_docker_env

# A prior run's containers may have left run/volumes/* with directory
# permissions the host build user can't traverse (see fix_volume_permissions
# in lib.sh) -- fix that before the api/web build context is read.
fix_volume_permissions

echo "Building api and web images from the current checkout..."
compose build api web

echo "Starting the service graph..."
compose up -d

write_base_url
BASE_URL="$(read_base_url)"

echo "Waiting for ${BASE_URL} to answer (setup status endpoint)..."
deadline=$(( $(date +%s) + 300 ))
until curl -fsS "${BASE_URL}/console/api/setup" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: ${BASE_URL} did not become healthy within 300s." >&2
    echo "Recent logs:" >&2
    compose logs --tail=80 nginx api web >&2 || true
    exit 1
  fi
  sleep 3
done

echo "Dify is up at ${BASE_URL}"
