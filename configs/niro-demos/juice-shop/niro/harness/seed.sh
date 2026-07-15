#!/usr/bin/env bash
# seed: ensure Juice Shop is running with its deterministic baseline (every
# boot runs sequelize.sync({force:true}) + data/datacreator.ts, so the
# baseline is already fresh whenever the server is up — see server.ts
# start()), then (re)generate ../credentials.yaml and ../fixtures.yaml from
# the same static seed data. Idempotent: does not restart an already-running
# instance. Use reset.sh to force a brand-new baseline.
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HARNESS_DIR/lib.sh"

start_app

log "generating credentials.yaml and fixtures.yaml"
node "$HARNESS_DIR/generate-manifests.cjs"
log "seed complete"
