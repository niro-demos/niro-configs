#!/usr/bin/env bash
# stop.sh — Shut down DVWA and supporting services cleanly.
#
# Preserves the DB volume so restarts are fast. Use reset.sh to reset data, or
# `docker compose down -v` to wipe volumes entirely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.harness.yml"

echo "[stop] shutting down DVWA"
docker compose -f "$COMPOSE_FILE" --project-name niro-dvwa down
echo "[stop] done"
