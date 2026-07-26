#!/usr/bin/env bash
# Shared config/helpers for the Sieve harness scripts.
# Sourced by start.sh / stop.sh / seed.sh / reset.sh — not run directly.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(dirname "$HARNESS_DIR")"
REPO_ROOT="$(dirname "$NIRO_DIR")"
RUN_DIR="$HARNESS_DIR/run"

IMAGE_NAME="sieve-niro:latest"
CONTAINER_NAME="sieve-niro"
HOST_PORT="5000"
BASE_URL="http://localhost:${HOST_PORT}"

mkdir -p "$RUN_DIR"

container_running() {
  docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' \
    | grep -qx "$CONTAINER_NAME"
}

container_exists() {
  docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' \
    | grep -qx "$CONTAINER_NAME"
}

wait_for_health() {
  local timeout="${1:-30}"
  local waited=0
  until curl -fsS -o /dev/null "${BASE_URL}/" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout" ]; then
      echo "sieve: app did not become healthy at ${BASE_URL}/ within ${timeout}s" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}
