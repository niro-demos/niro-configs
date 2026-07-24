#!/usr/bin/env bash
# Restore Sieve to its clean baseline. Sieve keeps all state (USERS, TOKENS)
# in-memory with no persistence, so a process restart is a complete and
# sufficient reset -- no separate data-wipe step is needed. credentials.yaml
# and fixtures.yaml describe fixed, code-level seed data that never changes
# across restarts, so they don't need to be regenerated here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
CONTAINER_NAME="sieve-niro-harness"

HOST_PORT="${SIEVE_HOST_PORT:-5000}"
BASE_URL="http://localhost:${HOST_PORT}"
if [ -f "$RUN_DIR/base_url" ]; then
  BASE_URL="$(cat "$RUN_DIR/base_url")"
fi

if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "[reset] no container named $CONTAINER_NAME found; run start.sh first." >&2
  exit 1
fi

echo "[reset] restarting $CONTAINER_NAME to clear in-memory state..."
docker restart "$CONTAINER_NAME" >/dev/null

echo "[reset] waiting for $BASE_URL/ to become healthy..."
ATTEMPTS=30
until curl -fsS "$BASE_URL/" >/dev/null 2>&1; do
  ATTEMPTS=$((ATTEMPTS - 1))
  if [ "$ATTEMPTS" -le 0 ]; then
    echo "[reset] FAILED: app did not become healthy after restart" >&2
    exit 1
  fi
  sleep 1
done

echo "[reset] healthy: $BASE_URL/"
