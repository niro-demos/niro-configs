#!/usr/bin/env bash
# Niro harness: build the current checkout and start the full Dify stack
# (nginx, web, api, worker, worker_beat, agent_backend, postgres, redis,
# weaviate, sandbox, ssrf_proxy, plugin_daemon, local_sandbox).
#
# api / web / agent_backend are built from THIS checkout's own Dockerfiles
# (context/dockerfile pairing documented in docker-compose.override.yaml;
# actually invoked via `docker buildx build` below -- see the comment at
# that step for why) so the target serves working-tree code, not langgenius'
# published images. Everything else (plugin_daemon, sandbox, local_sandbox,
# the datastores) has no source in this repo, so the project's own
# published-image defaults from docker/docker-compose.yaml are used
# unmodified.
#
# Idempotent / incremental: re-running this after a code change rebuilds only
# what changed (Docker layer + BuildKit cache) and reuses containers that are
# already healthy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"
ENV_FILE="${DOCKER_DIR}/.env"
PROJECT_NAME="dify-niro"
HTTP_PORT="${NIRO_DIFY_HTTP_PORT:-80}"

COMPOSE_ARGS=(
  -p "${PROJECT_NAME}"
  -f "${DOCKER_DIR}/docker-compose.yaml"
  -f "${SCRIPT_DIR}/docker-compose.override.yaml"
  --env-file "${ENV_FILE}"
)

log() { echo "[start] $*" >&2; }

# ---------------------------------------------------------------------------
# 1. Standard Dify deployment config: docker/.env, the project's own
#    documented way to configure docker/docker-compose.yaml ("copy this file
#    to .env and run: docker compose up -d", per docker/.env.example). This
#    is a normal build/config artifact -- gitignored by docker/.gitignore --
#    not harness-owned state, so it lives at docker/.env like any other
#    Dify deployment, rather than under niro/harness/run/.
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  log "docker/.env not found; generating from docker/.env.example"
  cp "${DOCKER_DIR}/.env.example" "${ENV_FILE}"
  SECRET_KEY="$(python3 -c 'import secrets; print(secrets.token_urlsafe(42))')"
  # Portable in-place sed for both GNU and BSD sed.
  sed -i.bak "s|^SECRET_KEY=.*|SECRET_KEY=${SECRET_KEY}|" "${ENV_FILE}"
  sed -i.bak "s|^EXPOSE_NGINX_PORT=.*|EXPOSE_NGINX_PORT=${HTTP_PORT}|" "${ENV_FILE}"
  rm -f "${ENV_FILE}.bak"
else
  log "reusing existing docker/.env"
fi

# ---------------------------------------------------------------------------
# 2. Build this checkout's services, then bring the full graph up.
#
# Neither `docker compose build` (buildx bake) nor a plain `docker buildx
# build` can safely use the repo root as build context once `docker compose
# up` has run at least once: postgres creates docker/volumes/db/data/pgdata
# as a service-uid-owned, mode-700 directory, and BuildKit's context walk
# (needed for web/Dockerfile's `COPY . .`) tries to descend into it and gets
# EACCES -- regardless of api/Dockerfile.dockerignore / web/Dockerfile.dockerignore
# excluding it, because the walker still has to enumerate a directory before
# it can decide an exclude rule applies. (chmod'ing it open is not an option:
# Postgres refuses to start against a data directory that isn't exactly
# owner-only.)
#
# So the build context is a synced copy of the working tree, minus
# docker/volumes/ and .git/, rather than the working tree itself. rsync's
# --exclude is applied at docker/volumes/ itself (which IS readable) before
# it ever tries to recurse into pgdata, so this never touches the
# unreadable path. This is "build output", explicitly fine to keep under
# niro/harness/run/ per harness/README.md.
# ---------------------------------------------------------------------------
BUILD_CTX="${SCRIPT_DIR}/run/build-context"
mkdir -p "${BUILD_CTX}"
log "syncing a build context at ${BUILD_CTX} (working tree minus docker/volumes/ and .git/)"
rsync -a --delete \
  --exclude='/docker/volumes/' \
  --exclude='/.git/' \
  --exclude='/niro/harness/run/' \
  "${REPO_ROOT}/" "${BUILD_CTX}/"

log "building api / web / agent_backend from the current checkout (this can take several minutes on a cold cache)"

declare -A DOCKERFILES=(
  [api]="api/Dockerfile"
  [web]="web/Dockerfile"
  [agent_backend]="dify-agent/Dockerfile"
)

for svc in api web agent_backend; do
  image="$(docker compose -f "${DOCKER_DIR}/docker-compose.yaml" --env-file "${ENV_FILE}" config \
    --format json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['services']['${svc}']['image'])")"
  log "building ${svc} -> ${image} (from ${DOCKERFILES[$svc]})"
  docker buildx build \
    -f "${BUILD_CTX}/${DOCKERFILES[$svc]}" \
    -t "${image}" \
    --load \
    "${BUILD_CTX}"
done

log "starting full service graph"
docker compose "${COMPOSE_ARGS[@]}" up -d

# ---------------------------------------------------------------------------
# 3. Wait for the surfaces Niro will actually test: nginx (customer-facing
#    origin), which fronts both the web app and the console/service APIs.
# ---------------------------------------------------------------------------
BASE_URL="http://localhost:${HTTP_PORT}"
log "waiting for ${BASE_URL} to become healthy"

DEADLINE=$((SECONDS + 900))
until curl -fsS -o /dev/null "${BASE_URL}/console/api/init" 2>/dev/null; do
  if (( SECONDS > DEADLINE )); then
    log "ERROR: ${BASE_URL}/console/api/init did not become healthy in time"
    docker compose "${COMPOSE_ARGS[@]}" ps
    exit 1
  fi
  sleep 3
done
log "console API is up"

DEADLINE=$((SECONDS + 300))
until curl -fsS -o /dev/null "${BASE_URL}/" 2>/dev/null; do
  if (( SECONDS > DEADLINE )); then
    log "ERROR: ${BASE_URL}/ (web frontend) did not become healthy in time"
    docker compose "${COMPOSE_ARGS[@]}" ps
    exit 1
  fi
  sleep 3
done
log "web frontend is up"

docker compose "${COMPOSE_ARGS[@]}" ps
log "stack is up. Target base URL: ${BASE_URL}"
