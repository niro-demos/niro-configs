#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"

"${SCRIPT_DIR}/stop.sh"
rm -f "${RUN_DIR}/seed.cookies"
mkdir -p "${RUN_DIR}/mysql"
docker run --rm -v "${RUN_DIR}/mysql:/mysql" mysql:8.0.25 bash -c 'shopt -s dotglob nullglob && rm -rf /mysql/*'
"${SCRIPT_DIR}/start.sh"
"${SCRIPT_DIR}/seed.sh"
