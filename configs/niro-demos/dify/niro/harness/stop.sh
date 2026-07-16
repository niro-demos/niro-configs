#!/usr/bin/env bash
# Shut down the Niro-managed Dify runtime cleanly. Data on disk under
# niro/harness/run/volumes/ is left in place (bind mounts), so a
# subsequent start.sh resumes from the same state; use reset.sh for a
# clean baseline instead.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

if [ ! -f "$ENV_FILE" ]; then
  echo "harness: nothing to stop ($ENV_FILE not found -- never started)."
  exit 0
fi

compose down --remove-orphans
echo "harness: stopped."
