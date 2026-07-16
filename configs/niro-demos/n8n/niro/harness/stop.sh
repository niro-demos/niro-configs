#!/usr/bin/env bash
# Shut down the n8n process started by start.sh. Idempotent.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

if [[ ! -f "$PID_FILE" ]]; then
	echo "n8n is not running (no pid file)."
	exit 0
fi

PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
	kill "$PID" 2>/dev/null || true
	for _ in $(seq 1 30); do
		kill -0 "$PID" 2>/dev/null || break
		sleep 1
	done
	kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
	echo "Stopped n8n (pid $PID)."
else
	echo "n8n process (pid $PID) was not running."
fi

rm -f "$PID_FILE"
