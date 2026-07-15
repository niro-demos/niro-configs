#!/usr/bin/env bash
# Restore the clean deterministic baseline: stop the server, wipe the sqlite
# DB file (and session tmp dir) so the NEXT start rebuilds everything from
# object.InitDb() + init_data.seed.json from scratch — including the
# built-in admin, in case a run mutated it (password change, lockout, etc.)
# — then start again and re-render credentials.yaml/fixtures.yaml so the DB
# and the manifest describing it never drift apart.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HARNESS_DIR/lib.sh"

"$HARNESS_DIR/stop.sh"

echo "[reset] wiping sqlite DB and session state for a clean baseline"
rm -f "$DB_FILE" "${DB_FILE}-shm" "${DB_FILE}-wal" "${DB_FILE}-journal"
rm -rf "$SERVE_DIR/tmp" "$SERVE_DIR/files"
mkdir -p "$SERVE_DIR/tmp" "$SERVE_DIR/files"

"$HARNESS_DIR/seed.sh"

echo "[reset] clean baseline restored at $BASE_URL"
