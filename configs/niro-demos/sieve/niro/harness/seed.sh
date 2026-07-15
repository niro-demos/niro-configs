#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
RUN_DIR="$HARNESS_DIR/run"
BASE_URL="http://127.0.0.1:5000"

mkdir -p "$RUN_DIR"
curl --fail --silent --show-error "$BASE_URL/" >/dev/null

for actor in alice:alice-pw bob:bob-pw admin:admin-pw; do
  username="${actor%%:*}"
  password="${actor#*:}"
  curl --fail --silent --show-error \
    --header 'Content-Type: application/json' \
    --data "{\"username\":\"$username\",\"password\":\"$password\"}" \
    "$BASE_URL/login" >"$RUN_DIR/login-$username.json"
done

cat >"$RUN_DIR/credentials.yaml.new" <<'EOF'
credentials:
  - credential_id: STANDARD_USER_ALICE
    description: "Standard user Alice (id 1, non-admin), owning only account 1. Login with POST /login JSON {username,password}; use Bearer token from response. Pair with Bob to test cross-account access."
    type: username_password
    identifier: alice
    secret: alice-pw
  - credential_id: STANDARD_USER_BOB
    description: "Standard user Bob (id 2, non-admin), owning only account 2. Login with POST /login JSON {username,password}; use Bearer token from response. Pair with Alice to test cross-account access."
    type: username_password
    identifier: bob
    secret: bob-pw
  - credential_id: GLOBAL_ADMIN
    description: "Global administrator (id 3, admin=true), owning account 3 and intended to access /admin/users. Login with POST /login JSON {username,password}; use Bearer token from response."
    type: username_password
    identifier: admin
    secret: admin-pw
EOF

cat >"$RUN_DIR/fixtures.yaml.new" <<'EOF'
fixtures:
  - name: alice_account
    description: "Alice's distinct account for own-resource and horizontal authorization tests."
    value: {account_id: 1, username: alice}
  - name: bob_account
    description: "Bob's distinct account for own-resource and horizontal authorization tests."
    value: {account_id: 2, username: bob}
  - name: admin_account
    description: "Global administrator's account and privileged directory surface."
    value: {account_id: 3, username: admin, admin_users_path: /admin/users}
  - name: application_surfaces
    description: "Complete seeded HTTP surface exposed by this application runtime."
    value: {root: /, login: /login, accounts: /accounts/<id>, admin_users: /admin/users}
EOF

mv "$RUN_DIR/credentials.yaml.new" "$NIRO_DIR/credentials.yaml"
mv "$RUN_DIR/fixtures.yaml.new" "$NIRO_DIR/fixtures.yaml"
