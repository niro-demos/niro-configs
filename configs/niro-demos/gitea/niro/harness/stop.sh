#!/usr/bin/env bash
set -euo pipefail

run_dir=$(cd "$(dirname "$0")" && pwd)/run
docker rm -f niro-gitea-runtime >/dev/null 2>&1 || true
rm -f "$run_dir/gitea.container" "$run_dir/gitea.pid"
