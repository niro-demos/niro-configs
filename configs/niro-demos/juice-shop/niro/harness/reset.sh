#!/usr/bin/env bash
# Restore the clean deterministic baseline.
#
# Juice Shop wipes and recreates its whole state on every process boot
# (server.ts: `sequelize.sync({ force: true })` then `datacreator()`), so
# the fast, correct way to get a clean baseline is a restart: stop the
# running process, start a fresh one (which reseeds automatically), then
# re-emit credentials.yaml/fixtures.yaml so they stay in sync with the
# fresh boot (same logical actors/ids, since seeding is deterministic).

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${HARNESS_DIR}/stop.sh"
"${HARNESS_DIR}/start.sh"
"${HARNESS_DIR}/seed.sh"

echo "[reset] clean baseline restored" >&2
