#!/usr/bin/env bash
set -euo pipefail

HARNESS=$(cd "$(dirname "$0")" && pwd)
CONFIG=$(cd "$HARNESS/.." && pwd)
BASE=http://127.0.0.1:5000

login() {
  curl --fail --silent --show-error \
    --header 'Content-Type: application/json' \
    --data "{\"username\":\"$1\",\"password\":\"$2\"}" \
    "$BASE/login"
}

alice=$(login alice alice-pw)
bob=$(login bob bob-pw)
admin=$(login admin admin-pw)
test "$(printf '%s' "$alice" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" = token-1
test "$(printf '%s' "$bob" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" = token-2
test "$(printf '%s' "$admin" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')" = token-3

cat >"$CONFIG/credentials.yaml" <<'EOF'
credentials:
  - description: "Standard user Alice (account ID 1). Login with POST /login JSON {username,password}. Owns only account 1; pair with Bob to test horizontal account isolation. No admin capability."
    type: username_password
    identifier: alice
    secret: alice-pw
  - description: "Standard user Bob (account ID 2). Login with POST /login JSON {username,password}. Owns only account 2; pair with Alice to test horizontal account isolation. No admin capability."
    type: username_password
    identifier: bob
    secret: bob-pw
  - description: "Global admin (account ID 3, admin=true). Login with POST /login JSON {username,password}. Intended privileged comparator for /admin/users; standard users have no admin capability."
    type: username_password
    identifier: admin
    secret: admin-pw
EOF

cat >"$CONFIG/fixtures.yaml" <<'EOF'
fixtures:
  - name: alice_account
    description: "Alice's distinct account for owner and cross-user authorization tests."
    value: {id: 1, username: alice, path: /accounts/1}
  - name: bob_account
    description: "Bob's distinct account for owner and cross-user authorization tests."
    value: {id: 2, username: bob, path: /accounts/2}
  - name: admin_account
    description: "Global administrator account and privileged comparison identity."
    value: {id: 3, username: admin, path: /accounts/3}
  - name: admin_directory
    description: "User-directory endpoint intended for admin authorization testing."
    value: {path: /admin/users}
EOF

chmod 600 "$CONFIG/credentials.yaml"
