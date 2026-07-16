#!/usr/bin/env bash
# Provision the deterministic test baseline: two workspaces ("orgs"), each
# with an owner + normal member account, plus one fixture app and one
# fixture dataset per org. Writes ../credentials.yaml and ../fixtures.yaml.
#
# Idempotent -- safe to re-run against an already-seeded database (see
# seed_accounts.py's docstring). Starts the stack first if it isn't up.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

MARKER_START="===NIRO_SEED_JSON_START==="
MARKER_END="===NIRO_SEED_JSON_END==="

if ! curl -fsS -o /dev/null "http://localhost:${API_PORT}/health" 2>/dev/null; then
  echo "harness: api not reachable on :${API_PORT} yet -- starting the stack first..."
  ./start.sh
fi

echo "harness: running seed_accounts.py inside the api container..."
RAW_OUTPUT="$(compose exec -T -e PYTHONPATH=/app/api api python /niro-harness/seed_accounts.py)"

JSON_PAYLOAD="$(printf '%s\n' "$RAW_OUTPUT" | awk -v s="$MARKER_START" -v e="$MARKER_END" '
  $0 == s {flag=1; next}
  $0 == e {flag=0}
  flag {print}
')"

if [ -z "$JSON_PAYLOAD" ]; then
  echo "harness: seed_accounts.py did not print the expected JSON markers. Full output:" >&2
  printf '%s\n' "$RAW_OUTPUT" >&2
  exit 1
fi

printf '%s' "$JSON_PAYLOAD" | python3 "$HARNESS_DIR/render_manifests.py" "$NIRO_DIR"

echo "harness: wrote $NIRO_DIR/credentials.yaml and $NIRO_DIR/fixtures.yaml."
