#!/usr/bin/env bash
#
# Niro harness: stop
#
# Shuts down the crAPI docker-compose stack cleanly. Named volumes (Postgres,
# Mongo, Chroma) are preserved so a subsequent start.sh comes back with the
# same data; use reset.sh to actually wipe application data back to a clean
# seeded baseline.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
DOCKER_DIR="$REPO_ROOT/deploy/docker"

cd "$DOCKER_DIR"

echo "[stop] Stopping crAPI docker compose stack (volumes preserved)..."
docker compose -f docker-compose.yml --compatibility down
echo "[stop] Stopped."
