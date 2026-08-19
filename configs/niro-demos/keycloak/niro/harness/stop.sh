#!/usr/bin/env bash
# Stop the Keycloak dev server started by start.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if ! is_running; then
  echo "Keycloak dev server is not running."
  rm -f "$PID_FILE"
  exit 0
fi

PID="$(cat "$PID_FILE")"
echo "Stopping Keycloak dev server (pid $PID)..."
kill -TERM "$PID" 2>/dev/null || true

for i in $(seq 1 30); do
  if ! kill -0 "$PID" 2>/dev/null; then
    break
  fi
  sleep 1
done

if kill -0 "$PID" 2>/dev/null; then
  echo "Server did not stop gracefully; killing it."
  kill -KILL "$PID" 2>/dev/null || true
fi

rm -f "$PID_FILE"
echo "Stopped."
