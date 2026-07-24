#!/usr/bin/env bash
# Restore a clean baseline: wipe all runtime state (DB, redis, storage,
# vector store), restart the stack, and re-seed. Because seed.sh
# deterministically recreates the same logical actors (same emails/roles)
# every time, the DB and the credentials.yaml/fixtures.yaml manifests come
# back in sync.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

echo "Tearing down containers and volumes..."
if [ -f "${DOCKER_ENV_FILE}" ]; then
  compose down -v || true
fi

echo "Wiping runtime state under ${NIRO_RUN_DIR}/volumes ..."
if [ -d "${NIRO_RUN_DIR}/volumes" ]; then
  # Containers (postgres, redis, weaviate, ...) write these as their own
  # container-internal uids, so the host user often can't unlink them
  # directly. Delete via a throwaway container instead, which can act as
  # root over the bind-mounted directory.
  docker run --rm -v "${NIRO_RUN_DIR}/volumes:/target" busybox \
    sh -c 'rm -rf /target/..?* /target/.[!.]* /target/*'
  rmdir "${NIRO_RUN_DIR}/volumes" 2>/dev/null || rm -rf "${NIRO_RUN_DIR}/volumes"
fi

./start.sh
./seed.sh

echo "Reset complete."
