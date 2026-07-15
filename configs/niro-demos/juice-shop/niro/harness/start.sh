#!/usr/bin/env bash
# start: build the current checkout (if stale) and start OWASP Juice Shop.
# Idempotent — if a healthy instance we started is already running, this is a
# no-op. All runtime state (pid, logs, build stamp) lives under run/.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

start_app
echo "$BASE_URL"
