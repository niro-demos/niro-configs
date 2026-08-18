#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PORT="${NIRO_CASDOOR_PORT:-18000}"
BASE_URL="http://127.0.0.1:${PORT}"
COOKIE_JAR="${SCRIPT_DIR}/run/seed.cookies"

mkdir -p "${SCRIPT_DIR}/run"

api_post() {
  local path="$1"
  local body="$2"
  local response
  response="$(curl -fsS -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" \
    -H 'Content-Type: application/json' \
    -H 'Accept-Language: en' \
    -X POST "${BASE_URL}${path}" \
    --data "${body}")"
  if ! printf '%s' "${response}" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    echo "Request failed: ${path}" >&2
    echo "${response}" >&2
    exit 1
  fi
}

api_get_ok() {
  local path="$1"
  curl -fsS -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" "${BASE_URL}${path}" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"'
}

resource_exists() {
  local path="$1"
  local response
  response="$(curl -fsS -b "${COOKIE_JAR}" -c "${COOKIE_JAR}" "${BASE_URL}${path}")"
  printf '%s' "${response}" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"ok"' && ! printf '%s' "${response}" | grep -Eq '"data"[[:space:]]*:[[:space:]]*null'
}

restart_casdoor() {
  local project_root
  local override_file
  project_root="$(cd "${NIRO_DIR}/.." && pwd)"
  override_file="${SCRIPT_DIR}/run/compose.override.yml"
  (cd "${project_root}" && COMPOSE_PROJECT_NAME="${NIRO_COMPOSE_PROJECT_NAME:-niro_casdoor}" docker compose -f docker-compose.yml -f "${override_file}" restart casdoor)
  for _ in $(seq 1 60); do
    if curl -fsS "${BASE_URL}/api/health" >/dev/null; then
      return
    fi
    sleep 2
  done
  echo "Casdoor did not become healthy after enabling the webhook worker" >&2
  exit 1
}

for _ in $(seq 1 60); do
  if curl -fsS "${BASE_URL}/api/health" >/dev/null; then
    break
  fi
  sleep 2
done

rm -f "${COOKIE_JAR}"

api_post "/api/login" '{"application":"app-built-in","organization":"built-in","username":"admin","password":"123","signinMethod":"Password","type":"login"}'

seed_tenant() {
  local org="$1"
  local display="$2"
  local app="app-${org}"
  local callback_port="$3"

  if ! resource_exists "/api/get-organization?id=admin/${org}"; then
    api_post "/api/add-organization" "{\"owner\":\"admin\",\"name\":\"${org}\",\"displayName\":\"${display}\",\"websiteUrl\":\"${BASE_URL}\",\"passwordType\":\"bcrypt\",\"passwordOptions\":[\"AtLeast6\"],\"countryCodes\":[\"US\"],\"languages\":[\"en\"],\"isProfilePublic\":true,\"enableSoftDeletion\":false}"
  fi

  if ! resource_exists "/api/get-application?id=admin/${app}"; then
    api_post "/api/add-application" "{\"owner\":\"admin\",\"name\":\"${app}\",\"displayName\":\"${display} Password App\",\"organization\":\"${org}\",\"homepageUrl\":\"${BASE_URL}\",\"enablePassword\":true,\"enableSignUp\":true,\"signinMethods\":[{\"name\":\"Password\",\"displayName\":\"Password\",\"rule\":\"All\"}],\"signupItems\":[{\"name\":\"Username\",\"visible\":true,\"required\":true,\"prompted\":false,\"rule\":\"None\"},{\"name\":\"Password\",\"visible\":true,\"required\":true,\"prompted\":false,\"rule\":\"None\"}],\"grantTypes\":[\"password\",\"authorization_code\",\"refresh_token\"],\"redirectUris\":[\"http://localhost:${callback_port}/callback\"],\"tokenFormat\":\"JWT\",\"expireInHours\":168,\"failedSigninLimit\":5,\"failedSigninFrozenTime\":15}"
  fi
}

seed_user() {
  local org="$1"
  local name="$2"
  local display="$3"
  local email="$4"
  local phone="$5"
  local rank="$6"
  local is_admin="$7"
  local affiliation="$8"

  if ! resource_exists "/api/get-user?id=${org}/${name}"; then
    api_post "/api/add-user" "{\"owner\":\"${org}\",\"name\":\"${name}\",\"id\":\"niro-${org}-${name}\",\"type\":\"normal-user\",\"password\":\"NiroPass123\",\"displayName\":\"${display}\",\"email\":\"${email}\",\"phone\":\"${phone}\",\"countryCode\":\"US\",\"affiliation\":\"${affiliation}\",\"score\":2000,\"ranking\":${rank},\"isAdmin\":${is_admin},\"isForbidden\":false,\"isDeleted\":false,\"signupApplication\":\"app-${org}\",\"registerType\":\"Add User\",\"registerSource\":\"built-in/admin\",\"createdIp\":\"127.0.0.1\",\"properties\":{}}"
  fi
}

seed_tenant "niro-alpha" "Niro Alpha Tenant" "19001"
seed_tenant "niro-beta" "Niro Beta Tenant" "19002"

seed_user "niro-alpha" "alice" "Niro Alpha Alice" "niro-alpha-alice@example.test" "15555550101" 1 false "Niro alpha standard user A"
seed_user "niro-alpha" "bob" "Niro Alpha Bob" "niro-alpha-bob@example.test" "15555550102" 2 false "Niro alpha standard user B"
seed_user "niro-alpha" "admin" "Niro Alpha Admin" "niro-alpha-admin@example.test" "15555550103" 3 true "Niro alpha tenant admin"
seed_user "niro-beta" "alice" "Niro Beta Alice" "niro-beta-alice@example.test" "15555550201" 1 false "Niro beta standard user A"
seed_user "niro-beta" "bob" "Niro Beta Bob" "niro-beta-bob@example.test" "15555550202" 2 false "Niro beta standard user B"
seed_user "niro-beta" "admin" "Niro Beta Admin" "niro-beta-admin@example.test" "15555550203" 3 true "Niro beta tenant admin"

if ! resource_exists "/api/get-provider?id=admin/provider-niro-local-storage"; then
  api_post "/api/add-provider" "{\"owner\":\"admin\",\"name\":\"provider-niro-local-storage\",\"displayName\":\"Niro Local Storage\",\"category\":\"Storage\",\"type\":\"Local File System\",\"domain\":\"${BASE_URL}\",\"pathPrefix\":\"niro\"}"
fi

if ! resource_exists "/api/get-webhook?id=admin/webhook-niro-success&organization="; then
  api_post "/api/add-webhook" '{"owner":"admin","name":"webhook-niro-success","organization":"","url":"http://webhook-receiver:19080/success","method":"POST","contentType":"application/json","headers":[{"name":"X-Niro-Harness","value":"success"}],"events":["update-user"],"tokenFields":[],"objectFields":["All"],"isUserExtended":false,"singleOrgOnly":false,"isEnabled":true,"maxRetries":2,"retryInterval":1,"useExponentialBackoff":false}'
fi

if ! resource_exists "/api/get-webhook?id=admin/webhook-niro-retry&organization="; then
  api_post "/api/add-webhook" '{"owner":"admin","name":"webhook-niro-retry","organization":"","url":"http://webhook-receiver:19080/always-fail","method":"POST","contentType":"application/json","headers":[{"name":"X-Niro-Harness","value":"retry"}],"events":["update-user"],"tokenFields":[],"objectFields":["All"],"isUserExtended":false,"singleOrgOnly":false,"isEnabled":true,"maxRetries":2,"retryInterval":1,"useExponentialBackoff":false}'
fi

# The worker starts only when at least one webhook exists at process startup.
restart_casdoor
rm -f "${COOKIE_JAR}"
api_post "/api/login" '{"application":"app-built-in","organization":"built-in","username":"admin","password":"123","signinMethod":"Password","type":"login"}'

api_get_ok "/api/get-user?id=built-in/admin"
api_get_ok "/api/get-user?id=niro-alpha/alice"
api_get_ok "/api/get-user?id=niro-alpha/bob"
api_get_ok "/api/get-user?id=niro-alpha/admin"
api_get_ok "/api/get-user?id=niro-beta/alice"
api_get_ok "/api/get-user?id=niro-beta/bob"
api_get_ok "/api/get-user?id=niro-beta/admin"

cat > "${NIRO_DIR}/credentials.yaml" <<'EOF'
credentials:
  - credential_id: GLOBAL_ADMIN
    description: "Global Casdoor administrator. Login with POST /api/login JSON: application=app-built-in, organization=built-in, username=admin, password from secret, signinMethod=Password, type=login. Has global admin access to all organizations and admin APIs."
    type: username_password
    identifier: "built-in/admin"
    secret: "123"
  - credential_id: STANDARD_ALICE
    description: "Standard user A in tenant niro-alpha for horizontal and tenant-isolation tests. Login username=alice, organization=niro-alpha, application=app-niro-alpha, signinMethod=Password, type=login. Owns only Alpha Alice fixture references and has no admin flag."
    type: username_password
    identifier: "niro-alpha/alice"
    secret: "NiroPass123"
  - credential_id: STANDARD_BOB
    description: "Standard user B in tenant niro-alpha for same-tenant horizontal authorization tests. Login username=bob, organization=niro-alpha, application=app-niro-alpha, signinMethod=Password, type=login. Owns only Alpha Bob fixture references and has no admin flag."
    type: username_password
    identifier: "niro-alpha/bob"
    secret: "NiroPass123"
  - credential_id: TENANT_ALPHA_ADMIN
    description: "Tenant admin in organization niro-alpha. Login username=admin, organization=niro-alpha, application=app-niro-alpha, signinMethod=Password, type=login. Has Casdoor isAdmin=true within niro-alpha but is not the built-in global admin."
    type: username_password
    identifier: "niro-alpha/admin"
    secret: "NiroPass123"
  - credential_id: TENANT_BETA_ALICE
    description: "Standard user A in separate tenant niro-beta for cross-tenant isolation tests against niro-alpha actors and resources. Login username=alice, organization=niro-beta, application=app-niro-beta, signinMethod=Password, type=login. No admin flag."
    type: username_password
    identifier: "niro-beta/alice"
    secret: "NiroPass123"
  - credential_id: TENANT_BETA_BOB
    description: "Standard user B in separate tenant niro-beta for same-tenant horizontal tests and cross-tenant comparisons. Login username=bob, organization=niro-beta, application=app-niro-beta, signinMethod=Password, type=login. No admin flag."
    type: username_password
    identifier: "niro-beta/bob"
    secret: "NiroPass123"
  - credential_id: TENANT_BETA_ADMIN
    description: "Tenant admin in organization niro-beta. Login username=admin, organization=niro-beta, application=app-niro-beta, signinMethod=Password, type=login. Has Casdoor isAdmin=true within niro-beta but is not the built-in global admin."
    type: username_password
    identifier: "niro-beta/admin"
    secret: "NiroPass123"
EOF

cat > "${NIRO_DIR}/fixtures.yaml" <<EOF
fixtures:
  - name: target_url
    description: "Local Niro-managed Casdoor target URL for this checkout."
    value: "${BASE_URL}"
  - name: test_organizations
    description: "Dedicated seeded organizations for tenant isolation tests."
    value:
      - owner: admin
        name: niro-alpha
      - owner: admin
        name: niro-beta
  - name: alpha_application
    description: "Dedicated seeded application used for password login by niro-alpha actors."
    value:
      owner: admin
      name: app-niro-alpha
      organization: niro-alpha
      redirect_uri: http://localhost:19001/callback
  - name: beta_application
    description: "Dedicated seeded application used for password login by niro-beta actors."
    value:
      owner: admin
      name: app-niro-beta
      organization: niro-beta
      redirect_uri: http://localhost:19002/callback
  - name: seeded_users
    description: "Stable seeded actor IDs and ownership contexts."
    value:
      global_admin: built-in/admin
      alpha_admin: niro-alpha/admin
      alpha_alice: niro-alpha/alice
      alpha_bob: niro-alpha/bob
      beta_admin: niro-beta/admin
      beta_alice: niro-beta/alice
      beta_bob: niro-beta/bob
  - name: local_storage_provider
    description: "Filesystem-backed Storage provider for authenticated upload, metadata read, file read, and delete tests. Pass provider=provider-niro-local-storage on resource APIs."
    value:
      owner: admin
      name: provider-niro-local-storage
      type: Local File System
      path_prefix: niro
      public_file_base_url: ${BASE_URL}/files/niro
  - name: local_webhook_receivers
    description: "Internal-only webhook fixtures. The success receiver returns 200; the retry receiver always returns 503 so retry state and replay can be exercised through Casdoor's webhook-event APIs. Receiver evidence is persisted in harness/run/webhook/events.jsonl."
    value:
      success_webhook: admin/webhook-niro-success
      retry_webhook: admin/webhook-niro-retry
      success_url: http://webhook-receiver:19080/success
      retry_url: http://webhook-receiver:19080/always-fail
      trigger_event: update-user
EOF

echo "Seeded Niro actors and generated credentials.yaml / fixtures.yaml"
