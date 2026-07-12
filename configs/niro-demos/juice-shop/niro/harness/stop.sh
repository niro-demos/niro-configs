#!/usr/bin/env bash
# Shut down the Juice Shop instance started by start.sh.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${HARNESS_DIR}/run"
PID_FILE="${RUN_DIR}/server.pid"

if [[ -f "${PID_FILE}" ]]; then
  PID="$(cat "${PID_FILE}")"
  if kill -0 "${PID}" 2>/dev/null; then
    echo "[stop] stopping server (pid ${PID})..." >&2
    kill "${PID}" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "${PID}" 2>/dev/null || break
      sleep 1
    done
    kill -9 "${PID}" 2>/dev/null || true
  else
    echo "[stop] pid ${PID} not running" >&2
  fi
  rm -f "${PID_FILE}"
else
  echo "[stop] no pid file at ${PID_FILE}; nothing to do" >&2
fi

exit 0
