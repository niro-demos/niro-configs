#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$HARNESS_DIR/start.sh"
"$HARNESS_DIR/seed.sh"
