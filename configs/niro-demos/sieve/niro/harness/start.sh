#!/usr/bin/env bash
# Build Sieve from the current checkout and start it, reachable on localhost.
#
# Niro-managed runtime (no --url): this script owns the full lifecycle.
# Always builds from the working tree's Dockerfile — never a stale/prebuilt
# image — so the target reflects the code under test.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

echo "sieve: building image from ${REPO_ROOT} (Dockerfile)..." >&2
docker build -t "$IMAGE_NAME" "$REPO_ROOT" >"$RUN_DIR/build.log" 2>&1 \
  || { echo "sieve: build failed — see $RUN_DIR/build.log" >&2; tail -n 40 "$RUN_DIR/build.log" >&2; exit 1; }

if container_running; then
  echo "sieve: container '${CONTAINER_NAME}' already running; recreating from the freshly built image..." >&2
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
elif container_exists; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

docker run -d --rm \
  --name "$CONTAINER_NAME" \
  -p "${HOST_PORT}:5000" \
  "$IMAGE_NAME" >"$RUN_DIR/container_id" 2>"$RUN_DIR/run.log" \
  || { echo "sieve: failed to start container — see $RUN_DIR/run.log" >&2; cat "$RUN_DIR/run.log" >&2; exit 1; }

if ! wait_for_health 30; then
  echo "sieve: container logs:" >&2
  docker logs "$CONTAINER_NAME" >&2 || true
  exit 1
fi

echo "$BASE_URL" >"$RUN_DIR/url"
echo "sieve: up at ${BASE_URL}" >&2
