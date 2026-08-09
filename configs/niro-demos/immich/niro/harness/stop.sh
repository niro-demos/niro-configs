#!/usr/bin/env bash
# Shut down the Immich runtime cleanly. Data under niro/harness/run/ is left
# in place so a subsequent start.sh + seed.sh reproduces the same baseline
# without a full rebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

log "Stopping Immich (docker compose project: ${COMPOSE_PROJECT})..."
"${COMPOSE[@]}" down --remove-orphans
log "Stopped."
