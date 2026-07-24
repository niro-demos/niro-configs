#!/usr/bin/env bash
# Shut down the harness's Dify stack cleanly. Volumes under
# niro/harness/run/ are preserved (use reset.sh for a clean baseline).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

if [ ! -f "${DOCKER_ENV_FILE}" ]; then
  echo "Nothing to stop (no ${DOCKER_ENV_FILE}; harness was never started)."
  exit 0
fi

# Only to populate NIRO_NGINX_PORT/etc. for compose file interpolation
# (docker compose down doesn't need their actual values to find containers
# by project name, but warns loudly if they're unset).
ensure_secrets

compose down

# Leave run/volumes/* traversable by the host user (see
# fix_volume_permissions in lib.sh) so a later api/web build's context read
# doesn't trip over container-owned directory permissions.
fix_volume_permissions

echo "Stopped."
