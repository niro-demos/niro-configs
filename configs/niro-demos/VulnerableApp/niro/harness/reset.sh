#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
"$HARNESS_DIR/stop.sh"
"$HARNESS_DIR/start.sh"
"$HARNESS_DIR/seed.sh"
