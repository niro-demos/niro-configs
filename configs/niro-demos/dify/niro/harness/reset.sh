#!/usr/bin/env bash
# Niro harness: restore a clean baseline. Wipes the app's own persistent
# state (Postgres data, uploaded file storage, Redis data, the Weaviate
# vector index, installed plugins) and re-seeds from scratch, so a run that
# left junk data (extra apps, toggled settings, new members) never leaks into
# the next run. credentials.yaml/fixtures.yaml are re-emitted together with
# the database so they never drift from what's actually seeded (same seeded
# emails/roles/ids come back every time, since seed_dify.py is deterministic).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCKER_DIR="${REPO_ROOT}/docker"

log() { echo "[reset] $*" >&2; }

log "stopping the stack"
"${SCRIPT_DIR}/stop.sh"

log "wiping persistent app state under docker/volumes/"
# These bind-mount directories are created and chowned by the containers
# themselves (postgres uid 70, weaviate/redis/plugin_daemon's own uids), so
# the invoking host user can't remove them directly -- sudo is required, the
# same as any local dev teardown of container-owned bind mounts.
sudo rm -rf \
  "${DOCKER_DIR}/volumes/db/data" \
  "${DOCKER_DIR}/volumes/app/storage" \
  "${DOCKER_DIR}/volumes/redis/data" \
  "${DOCKER_DIR}/volumes/weaviate" \
  "${DOCKER_DIR}/volumes/plugin_daemon"

log "starting a fresh stack"
"${SCRIPT_DIR}/start.sh"

log "re-seeding"
"${SCRIPT_DIR}/seed.sh"

log "done"
