#!/usr/bin/env bash
# reset.sh — Restore the DVWA database to a clean seeded baseline between runs.
#
# Re-runs DVWA's own setup.php (which DROPs and CREATEs the database, then
# re-inserts all default users and data). Regenerates credentials.yaml and
# fixtures.yaml from the committed seed.sh generator so the DB and manifests
# stay in sync. Does NOT wipe the DB volume — setup.php handles the reset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[reset] resetting DVWA database to clean baseline"
"$SCRIPT_DIR/seed.sh"
echo "[reset] done"
