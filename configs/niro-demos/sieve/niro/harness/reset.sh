#!/usr/bin/env bash
# Restore Sieve to a clean baseline between runs.
#
# All mutable state (the TOKENS map built up by /login calls) lives in the
# Python process's memory; USERS itself is never mutated by any endpoint.
# Restarting the container is therefore both necessary and sufficient to
# drop accumulated tokens and return to the exact post-start baseline.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if container_running; then
  echo "sieve: restarting '${CONTAINER_NAME}' for a clean baseline..." >&2
  docker restart "$CONTAINER_NAME" >/dev/null
else
  echo "sieve: not running — starting fresh..." >&2
  "$SCRIPT_DIR/start.sh"
fi

wait_for_health 30
echo "$BASE_URL" >"$RUN_DIR/url"

# Re-emit credentials.yaml / fixtures.yaml from the generator so the derived
# triple (app state + these two files) stays in sync, and re-verify login.
"$SCRIPT_DIR/seed.sh"

echo "sieve: reset complete — baseline restored at ${BASE_URL}" >&2
