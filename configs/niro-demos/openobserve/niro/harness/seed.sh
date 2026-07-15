#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
base_url=http://127.0.0.1:5080
root_user=root@niro.test
root_password='NiroRoot-2026!'
user_password='NiroAdmin-2026!'

curl --fail --silent --show-error "$base_url/healthz" >/dev/null
for org in niro-a niro-b; do
  curl --fail --silent --show-error --user "$root_user:$root_password" \
    --header 'Content-Type: application/json' \
    --data '[{"actor":"harness","baseline":true}]' \
    "$base_url/api/$org/niro_fixture/_json" >/dev/null
done
for actor in 'niro-a admin-a@niro.test' 'niro-b admin-b@niro.test'; do
  read -r org email <<<"$actor"
  code=$(curl --silent --output /tmp/niro-seed-user.json --write-out '%{http_code}' \
    --user "$root_user:$root_password" \
    --header 'Content-Type: application/json' \
    --data "{\"email\":\"$email\",\"password\":\"$user_password\",\"role\":\"admin\"}" \
    "$base_url/api/$org/users")
  if [[ "$code" != 200 && "$code" != 400 ]]; then
    cat /tmp/niro-seed-user.json >&2
    exit 1
  fi
done
rm -f /tmp/niro-seed-user.json

for actor in 'niro-a tc23-retest-sa@niro.test' 'niro-b ordinary-sa-b@niro.test'; do
  read -r org email <<<"$actor"
  curl --silent --user "$root_user:$root_password" --request DELETE \
    "$base_url/api/$org/service_accounts/$email" >/dev/null
  response=$(curl --fail --silent --show-error \
    --user "$root_user:$root_password" \
    --header 'Content-Type: application/json' \
    --data "{\"email\":\"$email\",\"organization\":\"$org\",\"first_name\":\"Niro\",\"last_name\":\"Verifier\"}" \
    "$base_url/api/$org/service_accounts")
  token=$(jq -er '.token' <<<"$response")
  if [[ "$org" == niro-a ]]; then
    tc23_service_account_token=$token
  else
    ordinary_service_account_b_token=$token
  fi
done

cat >"$repo_root/niro/credentials.yaml" <<EOF
credentials:
  - credential_id: GLOBAL_ROOT
    description: "Instance root user with global administration capability across all organizations. HTTP Basic authentication uses this email and password. Owns the default organization and may access all administrative surfaces."
    type: username_password
    identifier: $root_user
    secret: $root_password
  - credential_id: ORG_ADMIN_A
    description: "Community-edition administrator A in organization 'niro-a'. HTTP Basic authentication uses this email and password. Community builds coerce created users to admin, so this actor has full administration of niro-a but no intended access to niro-b. Pair with ORG_ADMIN_B for cross-organization tests."
    type: username_password
    identifier: admin-a@niro.test
    secret: $user_password
  - credential_id: ORG_ADMIN_B
    description: "Community-edition administrator B in organization 'niro-b'. HTTP Basic authentication uses this email and password. Community builds coerce created users to admin, so this actor has full administration of niro-b but no intended access to niro-a. Pair with ORG_ADMIN_A for cross-organization tests."
    type: username_password
    identifier: admin-b@niro.test
    secret: $user_password
  - credential_id: TC23_RETEST_SERVICE_ACCOUNT
    description: "Ordinary ungranted service account in organization 'niro-a'. Authenticate with HTTP Basic using the service-account email as identifier and API token as secret. Has only the built-in service_account role and no custom role, folder grant, stream grant, or cross-organization entitlement."
    type: username_password
    identifier: tc23-retest-sa@niro.test
    secret: $tc23_service_account_token
  - credential_id: ORDINARY_SERVICE_ACCOUNT_B
    description: "Ordinary ungranted service account in organization 'niro-b'. Authenticate with HTTP Basic using the service-account email as identifier and API token as secret. Has only the built-in service_account role and no custom role, folder grant, stream grant, or cross-organization entitlement. Pair with TC23_RETEST_SERVICE_ACCOUNT for cross-organization checks."
    type: username_password
    identifier: ordinary-sa-b@niro.test
    secret: $ordinary_service_account_b_token
EOF

cat >"$repo_root/niro/fixtures.yaml" <<EOF
fixtures:
  - name: target_base_url
    description: "Base URL of the checkout-built OpenObserve API, web UI, Swagger UI, ingestion, and health surfaces."
    value: $base_url
  - name: isolated_organizations
    description: "Distinct seeded organizations and streams for cross-organization authorization tests. Each non-root actor administers only its corresponding organization."
    value:
      actor_a:
        organization: niro-a
        stream: niro_fixture
      actor_b:
        organization: niro-b
        stream: niro_fixture
  - name: actor_pair
    description: "Distinct same-role identities with separate organizations and streams for cross-identity authorization checks."
    value:
      actor_a: admin-a@niro.test
      actor_b: admin-b@niro.test
  - name: profiling_routes
    description: "Authenticated profiling surface enabled in the checkout-built runtime for live route coverage. Use GLOBAL_ROOT with HTTP Basic authentication."
    value:
      memory: /debug/profile/memory
      stats: /debug/profile/stats
      cpu: /debug/profile/cpu?duration=1&frequency=10
  - name: ordinary_service_accounts
    description: "Deterministic ordinary service-account identities with no custom grants. Use for verifier cases that require an ungranted machine actor and for cross-organization denial checks. Secrets are in credentials.yaml, not this fixture."
    value:
      tc23_retest:
        credential_id: TC23_RETEST_SERVICE_ACCOUNT
        email: tc23-retest-sa@niro.test
        organization: niro-a
        effective_role: service_account
        custom_grants: []
      paired_actor_b:
        credential_id: ORDINARY_SERVICE_ACCOUNT_B
        email: ordinary-sa-b@niro.test
        organization: niro-b
        effective_role: service_account
        custom_grants: []
EOF

curl --fail --silent --show-error --user "$root_user:$root_password" "$base_url/api/default/users" >/dev/null
curl --fail --silent --show-error "$base_url/swagger/index.html" >/dev/null
curl --fail --silent --show-error --user "$root_user:$root_password" "$base_url/debug/profile/stats" >/dev/null
