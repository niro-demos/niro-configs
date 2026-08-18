#!/usr/bin/env bash
# Create a deterministic baseline for testing Keycloak itself: the bootstrap
# admin identity plus a dedicated realm with non-admin test users, a
# realm-scoped admin, and OIDC clients. Idempotent — safe to re-run.
#
# Generates ../credentials.yaml and ../fixtures.yaml.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if ! is_running; then
  echo "Keycloak is not running yet; starting it first."
  "$SCRIPT_DIR/start.sh"
fi

echo "Authenticating as the bootstrap admin..."
ADMIN_TOKEN="$(admin_token)"
if [[ -z "$ADMIN_TOKEN" || "$ADMIN_TOKEN" == "null" ]]; then
  echo "Could not obtain an admin token. Is the bootstrap admin ($KC_BOOTSTRAP_ADMIN_USERNAME_DEFAULT) present?" >&2
  exit 1
fi

auth() { curl -sf -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }

# --- Realm ------------------------------------------------------------------
echo "Reconciling realm '$TEST_REALM'..."
if auth -o /dev/null -w '' "$BASE_URL/admin/realms/$TEST_REALM" 2>/dev/null; then
  auth -X PUT "$BASE_URL/admin/realms/$TEST_REALM" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "realm": "$TEST_REALM",
  "enabled": true,
  "registrationAllowed": true,
  "registrationEmailAsUsername": false,
  "resetPasswordAllowed": true,
  "verifyEmail": false,
  "loginWithEmailAllowed": true,
  "editUsernameAllowed": true,
  "duplicateEmailsAllowed": false
}
EOF
else
  curl -sf -X POST "$BASE_URL/admin/realms" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "realm": "$TEST_REALM",
  "enabled": true,
  "registrationAllowed": true,
  "registrationEmailAsUsername": false,
  "resetPasswordAllowed": true,
  "verifyEmail": false,
  "loginWithEmailAllowed": true,
  "editUsernameAllowed": true,
  "duplicateEmailsAllowed": false
}
EOF
fi

# --- Clients ------------------------------------------------------------------
echo "Reconciling client '$TEST_APP_CLIENT_ID' (public, browser + direct grant)..."
APP_CLIENT_UUID="$(auth "$BASE_URL/admin/realms/$TEST_REALM/clients?clientId=$TEST_APP_CLIENT_ID" | jq -r '.[0].id // empty')"
APP_CLIENT_JSON=$(cat <<EOF
{
  "clientId": "$TEST_APP_CLIENT_ID",
  "enabled": true,
  "publicClient": true,
  "protocol": "openid-connect",
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": true,
  "implicitFlowEnabled": false,
  "serviceAccountsEnabled": false,
  "redirectUris": ["http://localhost:8080/*"],
  "webOrigins": ["+"],
  "baseUrl": "http://localhost:8080/realms/$TEST_REALM/account/"
}
EOF
)
if [[ -n "$APP_CLIENT_UUID" ]]; then
  auth -X PUT "$BASE_URL/admin/realms/$TEST_REALM/clients/$APP_CLIENT_UUID" \
    -H "Content-Type: application/json" -d "$APP_CLIENT_JSON"
else
  auth -X POST "$BASE_URL/admin/realms/$TEST_REALM/clients" \
    -H "Content-Type: application/json" -d "$APP_CLIENT_JSON"
  APP_CLIENT_UUID="$(auth "$BASE_URL/admin/realms/$TEST_REALM/clients?clientId=$TEST_APP_CLIENT_ID" | jq -r '.[0].id')"
fi

echo "Reconciling client '$TEST_SERVICE_CLIENT_ID' (confidential, service account)..."
SVC_CLIENT_UUID="$(auth "$BASE_URL/admin/realms/$TEST_REALM/clients?clientId=$TEST_SERVICE_CLIENT_ID" | jq -r '.[0].id // empty')"
SVC_CLIENT_JSON=$(cat <<EOF
{
  "clientId": "$TEST_SERVICE_CLIENT_ID",
  "enabled": true,
  "publicClient": false,
  "protocol": "openid-connect",
  "standardFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": true,
  "secret": "$TEST_SERVICE_CLIENT_SECRET"
}
EOF
)
if [[ -n "$SVC_CLIENT_UUID" ]]; then
  auth -X PUT "$BASE_URL/admin/realms/$TEST_REALM/clients/$SVC_CLIENT_UUID" \
    -H "Content-Type: application/json" -d "$SVC_CLIENT_JSON"
else
  auth -X POST "$BASE_URL/admin/realms/$TEST_REALM/clients" \
    -H "Content-Type: application/json" -d "$SVC_CLIENT_JSON"
  SVC_CLIENT_UUID="$(auth "$BASE_URL/admin/realms/$TEST_REALM/clients?clientId=$TEST_SERVICE_CLIENT_ID" | jq -r '.[0].id')"
  # The create call above does not reliably persist an explicit "secret";
  # a follow-up PUT does. Re-apply so the secret matches TEST_SERVICE_CLIENT_SECRET.
  auth -X PUT "$BASE_URL/admin/realms/$TEST_REALM/clients/$SVC_CLIENT_UUID" \
    -H "Content-Type: application/json" -d "$SVC_CLIENT_JSON"
fi

# --- Groups (distinct ownership for horizontal-escalation testing) ---------
ensure_group() {
  local name="$1"
  local id
  id="$(auth "$BASE_URL/admin/realms/$TEST_REALM/groups?search=$name&exact=true" | jq -r '.[0].id // empty')"
  if [[ -z "$id" ]]; then
    auth -X POST "$BASE_URL/admin/realms/$TEST_REALM/groups" \
      -H "Content-Type: application/json" -d "{\"name\": \"$name\"}"
    id="$(auth "$BASE_URL/admin/realms/$TEST_REALM/groups?search=$name&exact=true" | jq -r '.[0].id')"
  fi
  echo "$id"
}
echo "Reconciling groups 'org-a' and 'org-b'..."
GROUP_A_ID="$(ensure_group org-a)"
GROUP_B_ID="$(ensure_group org-b)"

# --- Users --------------------------------------------------------------------
ensure_user() {
  local username="$1" email="$2" password="$3" first="$4" last="$5"
  local id
  id="$(auth "$BASE_URL/admin/realms/$TEST_REALM/users?username=$username&exact=true" | jq -r '.[0].id // empty')"
  if [[ -z "$id" ]]; then
    auth -X POST "$BASE_URL/admin/realms/$TEST_REALM/users" \
      -H "Content-Type: application/json" -d @- <<EOF
{
  "username": "$username",
  "email": "$email",
  "emailVerified": true,
  "enabled": true,
  "firstName": "$first",
  "lastName": "$last"
}
EOF
    id="$(auth "$BASE_URL/admin/realms/$TEST_REALM/users?username=$username&exact=true" | jq -r '.[0].id')"
  fi
  # Always reconcile the password to the deterministic value (non-temporary).
  auth -X PUT "$BASE_URL/admin/realms/$TEST_REALM/users/$id/reset-password" \
    -H "Content-Type: application/json" \
    -d "{\"type\": \"password\", \"value\": \"$password\", \"temporary\": false}"
  echo "$id"
}

echo "Reconciling users 'alice', 'bob', 'carol'..."
ALICE_ID="$(ensure_user "$ALICE_USERNAME" "$ALICE_EMAIL" "$ALICE_PASSWORD" "Alice" "StandardUserA")"
BOB_ID="$(ensure_user "$BOB_USERNAME" "$BOB_EMAIL" "$BOB_PASSWORD" "Bob" "StandardUserB")"
CAROL_ID="$(ensure_user "$CAROL_USERNAME" "$CAROL_EMAIL" "$CAROL_PASSWORD" "Carol" "RealmAdmin")"

add_to_group() {
  local user_id="$1" group_id="$2"
  auth -X PUT "$BASE_URL/admin/realms/$TEST_REALM/users/$user_id/groups/$group_id" -o /dev/null
}
add_to_group "$ALICE_ID" "$GROUP_A_ID"
add_to_group "$BOB_ID" "$GROUP_B_ID"

# --- Realm-scoped admin: carol can manage niro-test only, not master --------
echo "Granting carol realm-admin rights scoped to '$TEST_REALM' only..."
RM_CLIENT_UUID="$(auth "$BASE_URL/admin/realms/$TEST_REALM/clients?clientId=realm-management" | jq -r '.[0].id')"
REALM_ADMIN_ROLE="$(auth "$BASE_URL/admin/realms/$TEST_REALM/clients/$RM_CLIENT_UUID/roles/realm-admin")"
auth -X POST "$BASE_URL/admin/realms/$TEST_REALM/users/$CAROL_ID/role-mappings/clients/$RM_CLIENT_UUID" \
  -H "Content-Type: application/json" -d "[$REALM_ADMIN_ROLE]" >/dev/null

echo "Verifying non-admin logins..."
verify_login() {
  local username="$1" password="$2"
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$BASE_URL/realms/$TEST_REALM/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=$TEST_APP_CLIENT_ID" -d "username=$username" -d "password=$password" -d "grant_type=password")"
  if [[ "$status" != "200" ]]; then
    echo "  WARNING: login verification for $username returned HTTP $status" >&2
  else
    echo "  $username: OK"
  fi
}
verify_login "$ALICE_USERNAME" "$ALICE_PASSWORD"
verify_login "$BOB_USERNAME" "$BOB_PASSWORD"
verify_login "$CAROL_USERNAME" "$CAROL_PASSWORD"

SVC_STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  "$BASE_URL/realms/$TEST_REALM/protocol/openid-connect/token" \
  -d "client_id=$TEST_SERVICE_CLIENT_ID" -d "client_secret=$TEST_SERVICE_CLIENT_SECRET" -d "grant_type=client_credentials")"
if [[ "$SVC_STATUS" != "200" ]]; then
  echo "  WARNING: client_credentials verification for $TEST_SERVICE_CLIENT_ID returned HTTP $SVC_STATUS" >&2
else
  echo "  $TEST_SERVICE_CLIENT_ID: OK"
fi

# --- Emit credentials.yaml and fixtures.yaml ---------------------------------
ADMIN_USERNAME="${KC_BOOTSTRAP_ADMIN_USERNAME:-$KC_BOOTSTRAP_ADMIN_USERNAME_DEFAULT}"
ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-$KC_BOOTSTRAP_ADMIN_PASSWORD_DEFAULT}"

echo "Writing $NIRO_DIR/credentials.yaml ..."
cat > "$NIRO_DIR/credentials.yaml" <<EOF
# GENERATED by niro/harness/seed.sh. Do not edit by hand; re-run seed.sh.
credentials:
  - credential_id: GLOBAL_ADMIN
    description: "Bootstrap master-realm admin, created via KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD
      on first boot (org.keycloak.services.managers.ApplianceBootstrap). Holds the
      instance-wide 'admin' realm role in the master realm, which grants full control
      over every realm (master and $TEST_REALM), the Admin REST API
      (/admin/realms/*), and the Admin Console. Login: POST
      /realms/master/protocol/openid-connect/token with body {client_id=admin-cli,
      username, password, grant_type=password}. Use to verify that lower-privileged
      principals below (carol, alice, bob) cannot reach master-realm or
      cross-realm admin surfaces."
    type: username_password
    identifier: $ADMIN_USERNAME
    secret: "$ADMIN_PASSWORD"

  - credential_id: REALM_ADMIN
    description: "carol. Realm-scoped admin: holds the 'realm-admin' composite client
      role of the realm-management client, granted ONLY inside the '$TEST_REALM'
      realm (not master, not any other realm). Can manage users, clients, and
      roles within $TEST_REALM via /admin/realms/$TEST_REALM/*, but must be
      REJECTED by /admin/realms/master/* and by any other realm's admin
      endpoints. Login: POST /realms/$TEST_REALM/protocol/openid-connect/token
      with body {client_id=$TEST_APP_CLIENT_ID, username, password,
      grant_type=password}. Pair with GLOBAL_ADMIN to test realm-isolation of
      admin privileges (vertical/lateral escalation across realms)."
    type: username_password
    identifier: $CAROL_USERNAME
    secret: "$CAROL_PASSWORD"

  - credential_id: STANDARD_USER_A
    description: "alice. Plain, non-admin end user in realm '$TEST_REALM'. Member of
      group 'org-a' only; owns her own account (profile, sessions, consents,
      credentials) reachable at /realms/$TEST_REALM/account/* and via the
      Account REST API. Holds no admin or realm-management role. Login: POST
      /realms/$TEST_REALM/protocol/openid-connect/token with body
      {client_id=$TEST_APP_CLIENT_ID, username, password, grant_type=password}.
      Pair with STANDARD_USER_B for horizontal-escalation tests: authenticate as
      alice, attempt to read/modify bob's account data, sessions, or group
      'org-b', expect 403/404. Must be rejected by every /admin/realms/*
      endpoint (vertical escalation)."
    type: username_password
    identifier: $ALICE_USERNAME
    secret: "$ALICE_PASSWORD"

  - credential_id: STANDARD_USER_B
    description: "bob. Plain, non-admin end user in realm '$TEST_REALM'. Member of
      group 'org-b' only; owns his own account, distinct from alice's. Holds no
      admin or realm-management role. Login: same shape as STANDARD_USER_A.
      Use as the target/second identity for STANDARD_USER_A's
      horizontal-escalation tests, and symmetrically to attempt reading
      alice's data."
    type: username_password
    identifier: $BOB_USERNAME
    secret: "$BOB_PASSWORD"

  - credential_id: NIRO_TEST_SERVICE
    description: "Confidential OIDC client '$TEST_SERVICE_CLIENT_ID' in realm
      '$TEST_REALM' with a service account. identifier is the client_id,
      secret is the client_secret. Login (client credentials grant, NOT
      password grant): POST /realms/$TEST_REALM/protocol/openid-connect/token
      with body {client_id=$TEST_SERVICE_CLIENT_ID, client_secret,
      grant_type=client_credentials}. The resulting service-account token
      holds no realm-management roles by default. Use to probe whether the
      service-account code path is subject to the same authorization gating
      as human users, and whether it can be escalated by mapping extra roles."
    type: username_password
    identifier: $TEST_SERVICE_CLIENT_ID
    secret: "$TEST_SERVICE_CLIENT_SECRET"
EOF

echo "Writing $NIRO_DIR/fixtures.yaml ..."
cat > "$NIRO_DIR/fixtures.yaml" <<EOF
# GENERATED by niro/harness/seed.sh. Do not edit by hand; re-run seed.sh.
fixtures:
  - name: master_realm
    description: "The built-in master realm. Holds GLOBAL_ADMIN. Admin REST API
      root for master is /admin/realms/master."
    value:
      realm: master
      admin_console: $BASE_URL/admin/master/console/
      account_console: $BASE_URL/realms/master/account/

  - name: test_realm
    description: "Dedicated seeded realm for exercising authentication, account
      management, and admin console flows outside of master. Self-registration
      and self-service password reset are enabled; email verification is
      disabled (no SMTP configured in this harness, see
      accepted-coverage-gaps.yaml)."
    value:
      realm: $TEST_REALM
      issuer: $BASE_URL/realms/$TEST_REALM
      token_endpoint: $BASE_URL/realms/$TEST_REALM/protocol/openid-connect/token
      admin_console: $BASE_URL/admin/$TEST_REALM/console/
      account_console: $BASE_URL/realms/$TEST_REALM/account/
      registration_endpoint: $BASE_URL/realms/$TEST_REALM/protocol/openid-connect/registrations

  - name: test_app_client
    description: "Public OIDC client used for browser (authorization code) and
      direct-grant login flows against '$TEST_REALM'. Use client_id=$TEST_APP_CLIENT_ID
      when constructing login/token requests for STANDARD_USER_A,
      STANDARD_USER_B, and REALM_ADMIN."
    value:
      client_id: $TEST_APP_CLIENT_ID
      redirect_uris: ["http://localhost:8080/*"]

  - name: test_groups
    description: "Two groups in '$TEST_REALM' used to give alice and bob
      distinct, non-overlapping ownership so cross-user access attempts have
      something concrete to fail at."
    value:
      org_a:
        group_id: $GROUP_A_ID
        member: $ALICE_USERNAME
      org_b:
        group_id: $GROUP_B_ID
        member: $BOB_USERNAME

  - name: seeded_user_ids
    description: "Keycloak user UUIDs for the seeded principals, for direct
      /admin/realms/$TEST_REALM/users/{id} requests (e.g. alice attempting
      GET /admin/realms/$TEST_REALM/users/\$bob_id)."
    value:
      alice: $ALICE_ID
      bob: $BOB_ID
      carol: $CAROL_ID
EOF

echo "Seed complete."
echo "  Realm:  $TEST_REALM"
echo "  Users:  $ALICE_USERNAME, $BOB_USERNAME, $CAROL_USERNAME (+ master admin)"
