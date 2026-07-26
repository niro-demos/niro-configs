#!/usr/bin/env bash
# Shut down the Sieve container started by start.sh.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if container_exists; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "sieve: stopped '${CONTAINER_NAME}'" >&2
else
  echo "sieve: '${CONTAINER_NAME}' is not running" >&2
fi

rm -f "$RUN_DIR/url" "$RUN_DIR/container_id"
