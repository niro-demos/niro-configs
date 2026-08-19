#!/usr/bin/env bash
# Restore the clean seeded baseline: wipe the dev database and re-seed.
#
# Deterministic re-seed fallback (no golden-snapshot copy): the bootstrap
# admin, the test realm, and the test users are fully re-derived from
# seed.sh, so the DB and the generated credentials.yaml/fixtures.yaml stay in
# sync as one atomic unit. Testing may have mutated passwords, sessions,
# groups, or added throwaway realm objects — this clears all of it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

echo "Resetting Keycloak dev server to a clean seeded baseline..."

if is_running; then
  "$SCRIPT_DIR/stop.sh"
fi

if [[ -d "$KC_HOME_DIR" ]]; then
  echo "Wiping dev database at $KC_HOME_DIR ..."
  rm -rf "$KC_HOME_DIR"
fi

"$SCRIPT_DIR/start.sh"
"$SCRIPT_DIR/seed.sh"

echo "Reset complete: clean baseline restored."
