#!/usr/bin/env bash
# Stop the Casdoor server started by start.sh. Leaves the sqlite DB file and
# build output in place — use reset.sh to wipe state.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HARNESS_DIR/lib.sh"

if ! pid="$(server_pid)"; then
  echo "[stop] no running server (pidfile absent or stale)"
  rm -f "$PID_FILE"
  exit 0
fi

echo "[stop] stopping casdoor (pid $pid)"
kill "$pid" 2>/dev/null || true

for _ in $(seq 1 20); do
  if ! kill -0 "$pid" 2>/dev/null; then
    break
  fi
  sleep 0.5
done

if kill -0 "$pid" 2>/dev/null; then
  echo "[stop] pid $pid did not exit in time, sending SIGKILL"
  kill -9 "$pid" 2>/dev/null || true
fi

rm -f "$PID_FILE"
echo "[stop] stopped"
