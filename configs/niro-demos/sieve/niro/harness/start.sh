#!/usr/bin/env bash
# Build the current checkout's Dockerfile and start Sieve as a Niro-managed
# application runtime. Idempotent: safe to re-run; replaces any prior
# container of the same name so the running app always matches the checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
mkdir -p "$RUN_DIR"

IMAGE_NAME="sieve-niro:latest"
CONTAINER_NAME="sieve-niro-harness"
HOST_PORT="${SIEVE_HOST_PORT:-5000}"
BASE_URL="http://localhost:${HOST_PORT}"

echo "$BASE_URL" > "$RUN_DIR/base_url"

echo "[start] building image from current checkout ($REPO_ROOT)..."
docker build -t "$IMAGE_NAME" "$REPO_ROOT" >"$RUN_DIR/build.log" 2>&1

# Remove any previous container of the same name so we never serve a stale build.
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "[start] removing existing container $CONTAINER_NAME..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

echo "[start] starting container $CONTAINER_NAME on port $HOST_PORT..."
docker run -d \
  --name "$CONTAINER_NAME" \
  -p "${HOST_PORT}:5000" \
  "$IMAGE_NAME" >"$RUN_DIR/container_id"

docker logs -f "$CONTAINER_NAME" >"$RUN_DIR/container.log" 2>&1 &
echo $! > "$RUN_DIR/logger_pid"

echo "[start] waiting for $BASE_URL/ to become healthy..."
ATTEMPTS=30
until curl -fsS "$BASE_URL/" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS - 1))
  if [ "$ATTEMPTS" -le 0 ]; then
    echo "[start] FAILED: app did not become healthy in time" >&2
    echo "----- container.log -----" >&2
    tail -n 100 "$RUN_DIR/container.log" >&2 || true
    exit 1
  fi
  sleep 1
done

echo "[start] healthy: $BASE_URL/"
curl -fsS "$BASE_URL/"
echo
