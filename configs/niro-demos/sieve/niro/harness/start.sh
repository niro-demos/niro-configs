#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
RUN_DIR="$HARNESS_DIR/run"
CONTAINER_NAME="sieve-niro"
IMAGE_NAME="sieve-niro:working-tree"

mkdir -p "$RUN_DIR"

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  docker rm -f "$CONTAINER_NAME" >/dev/null
fi

docker build --tag "$IMAGE_NAME" "$PROJECT_ROOT" >"$RUN_DIR/build.log" 2>&1
docker run --detach --rm \
  --name "$CONTAINER_NAME" \
  --publish 0.0.0.0:5000:5000 \
  "$IMAGE_NAME" >"$RUN_DIR/container.id"

for _ in $(seq 1 40); do
  if curl --fail --silent http://127.0.0.1:5000/ >"$RUN_DIR/health.json" 2>/dev/null; then
    exit 0
  fi
  sleep 0.25
done

docker logs "$CONTAINER_NAME" >&2 || true
exit 1
