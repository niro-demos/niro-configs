#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
"$HERE/stop.sh"
rm -f "$HERE/run/casdoor.db" "$HERE/run/casdoor.db-shm" "$HERE/run/casdoor.db-wal"
docker run --rm -v "$HERE/run:/harness-run" ubuntu:24.04 rm -rf /harness-run/mysql
"$HERE/start.sh"
"$HERE/seed.sh"
