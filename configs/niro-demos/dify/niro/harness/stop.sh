#!/usr/bin/env bash
# Shut down everything start.sh brought up: the web, celery, and api
# background processes, then the docker-compose middleware stack.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=support/common.sh
source ./support/common.sh

for name in web celery api; do
  stop_background "$name"
done

log "Stopping middleware (docker compose down)..."
e2e_tsx ./scripts/setup.ts middleware-down || log "middleware-down reported an error (continuing)"

log "Stopped."
