#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RUN="$ROOT/niro/harness/run"
IMAGE="sieve-niro-local:working-tree"
CONTAINER="sieve-niro-local"
DOCKER_GATEWAY=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')

mkdir -p "$RUN"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker build --tag "$IMAGE" "$ROOT"
docker run --detach --name "$CONTAINER" \
  --publish 127.0.0.1:5000:5000 \
  --publish "$DOCKER_GATEWAY:5000:5000" \
  "$IMAGE" >"$RUN/container-id"

for _ in $(seq 1 30); do
  if curl --fail --silent --show-error http://127.0.0.1:5000/ >"$RUN/health.json"; then
    exit 0
  fi
  sleep 1
done

docker logs "$CONTAINER" >&2
exit 1
