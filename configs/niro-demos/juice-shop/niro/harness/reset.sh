#!/usr/bin/env bash
# reset: restore the clean baseline. Juice Shop rebuilds its entire dataset
# (sqlite via sequelize.sync({force:true}) + MongoDB/MarsDB collections) from
# static seed data on every process start (server.ts start()), so a clean
# baseline is just a restart — no separate DB-wipe step is needed or exists.
# Then regenerate ../credentials.yaml and ../fixtures.yaml so they stay in
# sync with the (identical, deterministic) freshly seeded state.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HARNESS_DIR/lib.sh"

stop_app
start_app

log "generating credentials.yaml and fixtures.yaml"
node "$HARNESS_DIR/generate-manifests.cjs"
log "reset complete"
