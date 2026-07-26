#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_DIR="$ROOT_DIR/niro/harness/run"

"$ROOT_DIR/niro/harness/stop.sh"
mkdir -p "$RUN_DIR/files"
find "$RUN_DIR" -maxdepth 1 -type f \( -name 'vikunja.db' -o -name 'vikunja.db-shm' -o -name 'vikunja.db-wal' \) -delete
find "$RUN_DIR/files" -mindepth 1 -delete
"$ROOT_DIR/niro/harness/start.sh"
"$ROOT_DIR/niro/harness/seed.sh"
