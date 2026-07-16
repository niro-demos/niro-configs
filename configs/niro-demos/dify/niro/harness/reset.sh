#!/usr/bin/env bash
# Restore a clean baseline: wipe app/vector/redis state and re-seed, so the
# DB and ../credentials.yaml / ../fixtures.yaml come back in sync with the
# same logical actors (same emails/roles), per the harness contract. Kept
# secrets (SECRET_KEY, DB passwords in run/.env) are NOT rotated, only data.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

echo "harness: resetting to a clean baseline..."
compose down --remove-orphans

# The db/pgvector/redis containers write these as their own container
# uid (e.g. postgres' uid 999), so the host user can't just rm -rf them;
# do it as root in a disposable container sharing the same bind mount.
docker run --rm -v "$RUN_DIR/volumes:/target" alpine \
  sh -c 'rm -rf /target/db/* /target/db/.[!.]* /target/pgvector/* /target/pgvector/.[!.]* /target/redis/* /target/storage/* /target/plugin_daemon/* 2>/dev/null; true'

./start.sh
./seed.sh
