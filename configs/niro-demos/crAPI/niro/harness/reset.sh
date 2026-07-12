#!/usr/bin/env bash
#
# Niro harness: reset
#
# Restores a clean, deterministic application baseline between find sweeps.
# This only touches crAPI's own application data (Postgres/Mongo/Chroma
# volumes) and re-seeds via the app's own boot-time seeders — it does not
# touch Niro's pentest session/findings, which live entirely outside this
# docker-compose project.
#
# Approach: deterministic re-seed (the documented fallback when there's no
# golden snapshot). crAPI's seeders are all "create if empty"
# (services/identity/.../InitialDataConfig.java,
# services/workshop/.../seed_database.py,
# services/community/api/seed/seeder.go), so the fastest reliable way to get
# back to exactly the seeded baseline — undoing locked accounts, changed
# passwords, new/edited forum posts and comments, redeemed coupons, returned
# orders, uploaded profile videos, etc. — is to drop the named data volumes
# and let every service reseed from scratch on the next boot. Images are
# reused (not rebuilt) since only data, not code, needs to reset here.
#
# Env overrides:
#   REBUILD_ON_RESET=1   Also rebuild images from the checkout before
#                         restarting (use if source changed since the last
#                         start/reset).

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
DOCKER_DIR="$REPO_ROOT/deploy/docker"

cd "$DOCKER_DIR"

echo "[reset] Tearing down crAPI containers and dropping application data volumes..."
docker compose -f docker-compose.yml --compatibility down -v

if [ "${REBUILD_ON_RESET:-0}" = "1" ]; then
  echo "[reset] REBUILD_ON_RESET=1 set; rebuilding images before restart."
  SKIP_BUILD=0 "$HARNESS_DIR/start.sh"
else
  SKIP_BUILD=1 "$HARNESS_DIR/start.sh"
fi

echo "[reset] Reconciling seed data and regenerating credentials.yaml / fixtures.yaml..."
"$HARNESS_DIR/seed.sh"

echo "[reset] Clean baseline restored."
