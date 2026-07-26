#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="$ROOT_DIR/niro/harness/run"

stop_pid() {
	local name="$1"
	local pid_file="$RUN_DIR/$name.pid"
	if [[ ! -f "$pid_file" ]]; then
		return
	fi
	local pid
	pid="$(cat "$pid_file")"
	if kill -0 "$pid" 2>/dev/null; then
		kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
		for _ in $(seq 1 20); do
			if ! kill -0 "$pid" 2>/dev/null; then
				break
			fi
			sleep 0.5
		done
		if kill -0 "$pid" 2>/dev/null; then
			kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
		fi
	fi
	rm -f "$pid_file"
}

stop_pid frontend
stop_pid api

if [[ -d "$ROOT_DIR/frontend/node_modules" ]]; then
	pgrep -f "$ROOT_DIR/frontend/node_modules/.*/vite.*--host 0.0.0.0 --port 4173" | while read -r pid; do
		kill "$pid" 2>/dev/null || true
	done || true
fi
