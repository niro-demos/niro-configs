#!/usr/bin/env bash
# Restore the clean seeded baseline: truncate app-owned tables, wipe
# uploaded asset files, then re-run seed.sh so the SAME logical actors
# (same emails/IDs) come back. Requires the runtime to already be up
# (run start.sh first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if ! wait_for_ping 30; then
  log "immich-server is not reachable. Run start.sh first."
  exit 1
fi

TABLES=(
  stack
  library
  shared_link
  person
  album
  asset
  asset_face
  activity
  api_key
  session
  user
  tag
  integrity_report
)

log "Truncating app-owned tables: ${TABLES[*]}"
TABLE_LIST="$(printf '"%s", ' "${TABLES[@]}")"
TABLE_LIST="${TABLE_LIST%, }"
docker exec -i immich_niro_postgres psql -U postgres -d immich -v ON_ERROR_STOP=1 <<SQL
TRUNCATE ${TABLE_LIST} CASCADE;
DELETE FROM "system_metadata" WHERE "key" NOT IN ('reverse-geocoding-state', 'system-flags');
SQL

log "Clearing uploaded asset files under run/library..."
# The immich-server container writes these as root; a throwaway container
# (not a host `rm -rf`) is what can actually delete them regardless of the
# host user's permissions.
docker run --rm -v "${RUN_DIR}/library:/target" alpine:3 sh -c 'find /target -mindepth 1 -delete'

log "Re-seeding deterministic baseline..."
"${SCRIPT_DIR}/seed.sh"

log "Reset complete."
