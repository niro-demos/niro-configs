#!/usr/bin/env bash
# Shut down the Sieve harness container cleanly. Idempotent: safe to call
# even when nothing is running.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$SCRIPT_DIR/run"
CONTAINER_NAME="sieve-niro-harness"

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
  echo "[stop] stopping and removing container $CONTAINER_NAME..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
else
  echo "[stop] no container named $CONTAINER_NAME found; nothing to do."
fi

if [ -f "$RUN_DIR/logger_pid" ]; then
  PID="$(cat "$RUN_DIR/logger_pid" 2>/dev/null || true)"
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
  fi
  rm -f "$RUN_DIR/logger_pid"
fi

echo "[stop] done."
