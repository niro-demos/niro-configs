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

for _ in $(seq 1 60); do
  if curl -fsS "${BASE_URL}/api/health" >/dev/null; then
    break
  fi
  sleep 2
done

rm -f "${COOKIE_JAR}"

api_post "/api/login" '{"application":"app-built-in","organization":"built-in","username":"admin","password":"123","signinMethod":"Password","type":"login"}'

if ! resource_exists "/api/get-organization?id=admin/niro-test"; then
  api_post "/api/add-organization" "{\"owner\":\"admin\",\"name\":\"niro-test\",\"displayName\":\"Niro Test Organization\",\"websiteUrl\":\"${BASE_URL}\",\"passwordType\":\"bcrypt\",\"passwordOptions\":[\"AtLeast6\"],\"countryCodes\":[\"US\"],\"languages\":[\"en\"],\"isProfilePublic\":true,\"enableSoftDeletion\":false}"
fi

if ! resource_exists "/api/get-application?id=admin/app-niro-test"; then
  api_post "/api/add-application" "{\"owner\":\"admin\",\"name\":\"app-niro-test\",\"displayName\":\"Niro Test Application\",\"organization\":\"niro-test\",\"homepageUrl\":\"${BASE_URL}\",\"enablePassword\":true,\"enableSignUp\":true,\"signinMethods\":[{\"name\":\"Password\",\"displayName\":\"Password\",\"rule\":\"All\"}],\"signupItems\":[{\"name\":\"Username\",\"visible\":true,\"required\":true,\"prompted\":false,\"rule\":\"None\"},{\"name\":\"Password\",\"visible\":true,\"required\":true,\"prompted\":false,\"rule\":\"None\"}],\"grantTypes\":[\"password\",\"authorization_code\",\"refresh_token\"],\"redirectUris\":[\"http://localhost:9000/callback\"],\"tokenFormat\":\"JWT\",\"expireInHours\":168,\"failedSigninLimit\":5,\"failedSigninFrozenTime\":15}"
fi

if ! resource_exists "/api/get-user?id=niro-test/alice"; then
  api_post "/api/add-user" '{"owner":"niro-test","name":"alice","id":"niro-alice","type":"normal-user","password":"NiroPass123","displayName":"Niro Alice","email":"niro-alice@example.test","phone":"15555550101","countryCode":"US","affiliation":"Niro tenant A","score":2000,"ranking":1,"isAdmin":false,"isForbidden":false,"isDeleted":false,"signupApplication":"app-niro-test","registerType":"Add User","registerSource":"built-in/admin","createdIp":"127.0.0.1","properties":{}}'
fi
if ! resource_exists "/api/get-user?id=niro-test/bob"; then
  api_post "/api/add-user" '{"owner":"niro-test","name":"bob","id":"niro-bob","type":"normal-user","password":"NiroPass123","displayName":"Niro Bob","email":"niro-bob@example.test","phone":"15555550102","countryCode":"US","affiliation":"Niro tenant B","score":2000,"ranking":2,"isAdmin":false,"isForbidden":false,"isDeleted":false,"signupApplication":"app-niro-test","registerType":"Add User","registerSource":"built-in/admin","createdIp":"127.0.0.1","properties":{}}'
fi
if ! resource_exists "/api/get-user?id=niro-test/org-admin"; then
  api_post "/api/add-user" '{"owner":"niro-test","name":"org-admin","id":"niro-org-admin","type":"normal-user","password":"NiroPass123","displayName":"Niro Org Admin","email":"niro-org-admin@example.test","phone":"15555550103","countryCode":"US","affiliation":"Niro tenant admin","score":2000,"ranking":3,"isAdmin":true,"isForbidden":false,"isDeleted":false,"signupApplication":"app-niro-test","registerType":"Add User","registerSource":"built-in/admin","createdIp":"127.0.0.1","properties":{}}'
fi

api_get_ok "/api/get-user?id=built-in/admin"
api_get_ok "/api/get-user?id=niro-test/alice"
api_get_ok "/api/get-user?id=niro-test/bob"
api_get_ok "/api/get-user?id=niro-test/org-admin"

cat > "${NIRO_DIR}/credentials.yaml" <<'EOF'
credentials:
  - credential_id: GLOBAL_ADMIN
    description: "Global Casdoor administrator. Login with POST /api/login JSON: application=app-built-in, organization=built-in, username=admin, password from secret, signinMethod=Password, type=login. Has global admin access to all organizations and admin APIs."
    type: username_password
    identifier: "built-in/admin"
    secret: "123"
  - credential_id: STANDARD_ALICE
    description: "Standard user in organization niro-test for horizontal authorization tests. Login username=alice, organization=niro-test, application=app-niro-test, signinMethod=Password, type=login. Owns only Alice fixture references and has no admin flag."
    type: username_password
    identifier: "niro-test/alice"
    secret: "NiroPass123"
  - credential_id: STANDARD_BOB
    description: "Standard user in organization niro-test for horizontal authorization tests. Login username=bob, organization=niro-test, application=app-niro-test, signinMethod=Password, type=login. Owns only Bob fixture references and has no admin flag."
    type: username_password
    identifier: "niro-test/bob"
    secret: "NiroPass123"
  - credential_id: ORG_ADMIN
    description: "Organization admin in niro-test. Login username=org-admin, organization=niro-test, application=app-niro-test, signinMethod=Password, type=login. Has Casdoor isAdmin=true within niro-test but is not a built-in global admin."
    type: username_password
    identifier: "niro-test/org-admin"
    secret: "NiroPass123"
EOF

cat > "${NIRO_DIR}/fixtures.yaml" <<EOF
fixtures:
  - name: target_url
    description: "Local Niro-managed Casdoor target URL for this checkout."
    value: "${BASE_URL}"
  - name: test_organization
    description: "Dedicated seeded organization for non-global actor tests."
    value:
      owner: admin
      name: niro-test
  - name: test_application
    description: "Dedicated seeded application used for password login by niro-test actors."
    value:
      owner: admin
      name: app-niro-test
      organization: niro-test
  - name: seeded_users
    description: "Stable seeded actor IDs and ownership contexts."
    value:
      global_admin: built-in/admin
      org_admin: niro-test/org-admin
      standard_alice: niro-test/alice
      standard_bob: niro-test/bob
EOF

echo "Seeded Niro actors and generated credentials.yaml / fixtures.yaml"
