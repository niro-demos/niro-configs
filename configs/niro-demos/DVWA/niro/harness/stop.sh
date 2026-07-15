#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
docker compose -p niro-dvwa -f "$HARNESS_DIR/compose.yml" down --remove-orphans
