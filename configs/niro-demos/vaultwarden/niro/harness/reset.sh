#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/stop.sh"
rm -rf "${SCRIPT_DIR}/run/data" "${SCRIPT_DIR}/run/logs"
mkdir -p "${SCRIPT_DIR}/run/data" "${SCRIPT_DIR}/run/logs"
"${SCRIPT_DIR}/start.sh" >/dev/null
"${SCRIPT_DIR}/seed.sh"
