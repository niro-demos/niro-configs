#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
run_dir="$repo_root/niro/harness/run"
binary="$run_dir/gitea"
config="$run_dir/custom/conf/app.ini"
url=http://127.0.0.1:3300
password='Niro-test-2026!'

create_user() {
  local username=$1 email=$2 admin=$3
  local args=(admin user create --config "$config" --username "$username" --password "$password" --email "$email" --must-change-password=false)
  [[ "$admin" == true ]] && args+=(--admin)
  "$binary" "${args[@]}" >/dev/null 2>&1 || true
}

create_user niro-admin admin@niro.invalid true
create_user niro-alice alice@niro.invalid false
create_user niro-bob bob@niro.invalid false
create_user niro-charlie charlie@niro.invalid false

api() {
  local actor=$1 method=$2 path=$3 data=${4-}
  if [[ -n "$data" ]]; then
    curl --fail-with-body --silent --show-error -u "$actor:$password" -X "$method" \
      -H 'Content-Type: application/json' --data "$data" "$url/api/v1$path"
  else
    curl --fail-with-body --silent --show-error -u "$actor:$password" -X "$method" "$url/api/v1$path"
  fi
}

ensure_repo() {
  local actor=$1 repo=$2 private=$3
  api "$actor" GET "/repos/$actor/$repo" >/dev/null 2>&1 || \
    api "$actor" POST /user/repos "{\"name\":\"$repo\",\"description\":\"Niro-owned fixture for authorization and content testing\",\"private\":$private,\"auto_init\":true,\"default_branch\":\"main\"}" >/dev/null
}

ensure_repo niro-alice alice-private true
ensure_repo niro-alice alice-public false
ensure_repo niro-bob bob-private true
ensure_repo niro-bob bob-public false
ensure_repo niro-charlie charlie-private true

api niro-admin GET /orgs/niro-alpha >/dev/null 2>&1 || \
  api niro-admin POST /orgs '{"username":"niro-alpha","full_name":"Niro Alpha Organization","description":"Organization fixture for scoped authorization testing","visibility":"private"}' >/dev/null
api niro-admin GET /orgs/niro-beta >/dev/null 2>&1 || \
  api niro-admin POST /orgs '{"username":"niro-beta","full_name":"Niro Beta Organization","description":"Distinct organization fixture for cross-organization tests","visibility":"private"}' >/dev/null

cat >"$repo_root/niro/credentials.yaml" <<EOF
credentials:
  - description: "Global site administrator with unrestricted admin panel, user, organization, repository, and system-management privileges. Login through POST /user/login form fields user_name and password, or use HTTP Basic authentication on /api/v1. Use only as the high-privilege side of vertical authorization comparisons."
    type: username_password
    identifier: niro-admin
    secret: "$password"
  - description: "Standard individual user A; not a site admin. Owns alice-private and alice-public, and owns no Bob or Charlie repositories. Login through POST /user/login form fields user_name and password, or HTTP Basic on /api/v1. Pair with niro-bob for horizontal repository and profile authorization tests."
    type: username_password
    identifier: niro-alice
    secret: "$password"
  - description: "Standard individual user B; not a site admin. Owns bob-private and bob-public, distinct from Alice's resources. Login through POST /user/login form fields user_name and password, or HTTP Basic on /api/v1. Pair with niro-alice for horizontal authorization tests."
    type: username_password
    identifier: niro-bob
    secret: "$password"
  - description: "Standard individual user C; not a site admin. Owns charlie-private and is intentionally independent of Alice and Bob, providing a third principal for invitations, collaboration, issue, and transfer flows. Login through POST /user/login form fields user_name and password, or HTTP Basic on /api/v1."
    type: username_password
    identifier: niro-charlie
    secret: "$password"
EOF

cat >"$repo_root/niro/fixtures.yaml" <<EOF
fixtures:
  - name: runtime
    description: "Local working-tree Gitea runtime and its public API root."
    value:
      web_url: "$url/"
      api_url: "$url/api/v1"
      health_url: "$url/api/healthz"
  - name: alice_repositories
    description: "Repositories owned exclusively by niro-alice; use private repository for cross-user denial checks and public repository for anonymous/read behavior."
    value:
      private: "niro-alice/alice-private"
      public: "niro-alice/alice-public"
  - name: bob_repositories
    description: "Distinct repositories owned exclusively by niro-bob for paired horizontal-authorization checks."
    value:
      private: "niro-bob/bob-private"
      public: "niro-bob/bob-public"
  - name: charlie_repository
    description: "Third-user private repository for invitation, collaboration, transfer, issue, and access-control workflows."
    value: "niro-charlie/charlie-private"
  - name: organizations
    description: "Two distinct private organizations owned by the site-admin seed actor for cross-organization and team-management surface discovery."
    value:
      - niro-alpha
      - niro-beta
EOF
