#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_tool cargo
require_tool curl

write_runtime_env

if is_running; then
  wait_for_http "${TARGET_URL}/alive"
  echo "${TARGET_URL}"
  exit 0
fi

cd "${PROJECT_ROOT}"
cargo build --features sqlite

setsid "${PROJECT_ROOT}/target/debug/vaultwarden" >"${LOG_DIR}/vaultwarden.log" 2>&1 < /dev/null &
echo "$!" > "${PID_FILE}"

wait_for_http "${TARGET_URL}/alive"
echo "${TARGET_URL}"
