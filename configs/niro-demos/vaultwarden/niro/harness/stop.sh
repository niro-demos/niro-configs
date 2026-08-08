#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

if ! is_running; then
  rm -f "${PID_FILE}"
  exit 0
fi

pid="$(cat "${PID_FILE}")"
kill "${pid}" 2>/dev/null || true

for _ in $(seq 1 30); do
  if ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${PID_FILE}"
    exit 0
  fi
  sleep 1
done

kill -9 "${pid}" 2>/dev/null || true
rm -f "${PID_FILE}"
