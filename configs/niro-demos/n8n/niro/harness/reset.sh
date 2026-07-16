#!/usr/bin/env bash
# Restore the Niro-owned n8n target to a clean, freshly-seeded baseline:
# stop the process, wipe its sqlite DB + local user folder, start again, and
# re-run seed.sh so credentials.yaml/fixtures.yaml stay in sync with the DB.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

"$HARNESS_DIR/stop.sh"

rm -rf "$DATA_DIR"
mkdir -p "$DATA_DIR"
rm -rf "$RUN_DIR/cookies"

"$HARNESS_DIR/seed.sh"
