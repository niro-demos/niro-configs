#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_tool curl
require_tool jq
require_tool node
require_tool sqlite3

wait_for_http "${TARGET_URL}/alive"

hash_secret() {
  local secret="$1"
  local salt="$2"
  node -e 'const crypto=require("crypto"); const [secret,salt]=process.argv.slice(1); process.stdout.write(crypto.pbkdf2Sync(secret, Buffer.from(salt, "utf8"), 100000, 32, "sha256").toString("hex"));' "${secret}" "${salt}"
}

hex_blob() {
  local value="$1"
  node -e 'process.stdout.write(Buffer.from(process.argv[1], "utf8").toString("hex"));' "${value}"
}

NOW="2026-08-08 00:00:00"
FUTURE="2027-08-08 00:00:00"

USER_A_ID="11111111-1111-4111-8111-111111111111"
USER_B_ID="22222222-2222-4222-8222-222222222222"
OWNER_ID="33333333-3333-4333-8333-333333333333"
MEMBER_ID="44444444-4444-4444-8444-444444444444"

USER_A_EMAIL="niro-user-a@example.test"
USER_B_EMAIL="niro-user-b@example.test"
OWNER_EMAIL="niro-owner@example.test"
MEMBER_EMAIL="niro-member@example.test"

USER_A_SECRET="niro-user-a-master-auth-hash-2026"
USER_B_SECRET="niro-user-b-master-auth-hash-2026"
OWNER_SECRET="niro-owner-master-auth-hash-2026"
MEMBER_SECRET="niro-member-master-auth-hash-2026"

ORG_A_ID="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
ORG_B_ID="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
OWNER_MEMBERSHIP_ID="55555555-5555-4555-8555-555555555555"
MEMBER_MEMBERSHIP_ID="66666666-6666-4666-8666-666666666666"

USER_A_CIPHER_ID="77777777-7777-4777-8777-777777777777"
USER_B_CIPHER_ID="88888888-8888-4888-8888-888888888888"
ORG_A_CIPHER_ID="99999999-9999-4999-8999-999999999999"
ORG_B_CIPHER_ID="abababab-abab-4bab-8bab-abababababab"
USER_A_FOLDER_ID="12121212-1212-4121-8121-121212121212"
USER_B_FOLDER_ID="34343434-3434-4343-8343-343434343434"
SEND_A_ID="cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd"

sqlite3 "${DB_FILE}" <<SQL
.timeout 10000

DELETE FROM folders_ciphers WHERE cipher_uuid IN ('${USER_A_CIPHER_ID}', '${USER_B_CIPHER_ID}');
DELETE FROM ciphers WHERE uuid IN ('${USER_A_CIPHER_ID}', '${USER_B_CIPHER_ID}', '${ORG_A_CIPHER_ID}', '${ORG_B_CIPHER_ID}');
DELETE FROM folders WHERE uuid IN ('${USER_A_FOLDER_ID}', '${USER_B_FOLDER_ID}');
DELETE FROM users_organizations WHERE uuid IN ('${OWNER_MEMBERSHIP_ID}', '${MEMBER_MEMBERSHIP_ID}');
DELETE FROM organizations WHERE uuid IN ('${ORG_A_ID}', '${ORG_B_ID}');
DELETE FROM sends WHERE uuid IN ('${SEND_A_ID}');
DELETE FROM users WHERE uuid IN ('${USER_A_ID}', '${USER_B_ID}', '${OWNER_ID}', '${MEMBER_ID}')
  OR email IN ('${USER_A_EMAIL}', '${USER_B_EMAIL}', '${OWNER_EMAIL}', '${MEMBER_EMAIL}');

INSERT INTO users (uuid, enabled, created_at, updated_at, verified_at, last_verifying_at, login_verify_count, email, email_new, email_new_token, name, password_hash, salt, password_iterations, password_hint, akey, private_key, public_key, totp_secret, totp_recover, security_stamp, stamp_exception, equivalent_domains, excluded_globals, client_kdf_type, client_kdf_iter, client_kdf_memory, client_kdf_parallelism, api_key, avatar_color, external_id) VALUES
('${USER_A_ID}', 1, '${NOW}', '${NOW}', '${NOW}', NULL, 0, '${USER_A_EMAIL}', NULL, NULL, 'Niro User A', X'$(hash_secret "${USER_A_SECRET}" "niro-user-a-salt-2026")', X'$(hex_blob "niro-user-a-salt-2026")', 100000, NULL, 'niro-akey-user-a', NULL, NULL, NULL, NULL, 'stamp-user-a-2026', NULL, '[]', '[]', 0, 600000, NULL, NULL, NULL, NULL, NULL),
('${USER_B_ID}', 1, '${NOW}', '${NOW}', '${NOW}', NULL, 0, '${USER_B_EMAIL}', NULL, NULL, 'Niro User B', X'$(hash_secret "${USER_B_SECRET}" "niro-user-b-salt-2026")', X'$(hex_blob "niro-user-b-salt-2026")', 100000, NULL, 'niro-akey-user-b', NULL, NULL, NULL, NULL, 'stamp-user-b-2026', NULL, '[]', '[]', 0, 600000, NULL, NULL, NULL, NULL, NULL),
('${OWNER_ID}', 1, '${NOW}', '${NOW}', '${NOW}', NULL, 0, '${OWNER_EMAIL}', NULL, NULL, 'Niro Org Owner', X'$(hash_secret "${OWNER_SECRET}" "niro-owner-salt-2026")', X'$(hex_blob "niro-owner-salt-2026")', 100000, NULL, 'niro-akey-owner', NULL, NULL, NULL, NULL, 'stamp-owner-2026', NULL, '[]', '[]', 0, 600000, NULL, NULL, NULL, NULL, NULL),
('${MEMBER_ID}', 1, '${NOW}', '${NOW}', '${NOW}', NULL, 0, '${MEMBER_EMAIL}', NULL, NULL, 'Niro Org Member', X'$(hash_secret "${MEMBER_SECRET}" "niro-member-salt-2026")', X'$(hex_blob "niro-member-salt-2026")', 100000, NULL, 'niro-akey-member', NULL, NULL, NULL, NULL, 'stamp-member-2026', NULL, '[]', '[]', 0, 600000, NULL, NULL, NULL, NULL, NULL);

INSERT INTO organizations (uuid, name, billing_email, private_key, public_key) VALUES
('${ORG_A_ID}', 'Niro Org A', '${OWNER_EMAIL}', NULL, NULL),
('${ORG_B_ID}', 'Niro Org B', '${USER_B_EMAIL}', NULL, NULL);

INSERT INTO users_organizations (uuid, user_uuid, org_uuid, invited_by_email, access_all, akey, status, atype, reset_password_key, external_id) VALUES
('${OWNER_MEMBERSHIP_ID}', '${OWNER_ID}', '${ORG_A_ID}', NULL, 1, 'niro-org-owner-akey', 2, 0, NULL, NULL),
('${MEMBER_MEMBERSHIP_ID}', '${MEMBER_ID}', '${ORG_A_ID}', '${OWNER_EMAIL}', 0, 'niro-org-member-akey', 2, 2, NULL, NULL);

INSERT INTO folders (uuid, created_at, updated_at, user_uuid, name) VALUES
('${USER_A_FOLDER_ID}', '${NOW}', '${NOW}', '${USER_A_ID}', 'Niro User A Folder'),
('${USER_B_FOLDER_ID}', '${NOW}', '${NOW}', '${USER_B_ID}', 'Niro User B Folder');

INSERT INTO ciphers (uuid, created_at, updated_at, user_uuid, organization_uuid, key, atype, name, notes, fields, data, password_history, deleted_at, reprompt) VALUES
('${USER_A_CIPHER_ID}', '${NOW}', '${NOW}', '${USER_A_ID}', NULL, NULL, 2, 'Niro User A Private Note', 'Owned only by Niro User A', NULL, '{"type":0}', NULL, NULL, 0),
('${USER_B_CIPHER_ID}', '${NOW}', '${NOW}', '${USER_B_ID}', NULL, NULL, 2, 'Niro User B Private Note', 'Owned only by Niro User B', NULL, '{"type":0}', NULL, NULL, 0),
('${ORG_A_CIPHER_ID}', '${NOW}', '${NOW}', NULL, '${ORG_A_ID}', 'niro-org-a-key', 2, 'Niro Org A Shared Note', 'Owned by Niro Org A', NULL, '{"type":0}', NULL, NULL, 0),
('${ORG_B_CIPHER_ID}', '${NOW}', '${NOW}', NULL, '${ORG_B_ID}', 'niro-org-b-key', 2, 'Niro Org B Shared Note', 'Owned by Niro Org B', NULL, '{"type":0}', NULL, NULL, 0);

INSERT INTO folders_ciphers (cipher_uuid, folder_uuid) VALUES
('${USER_A_CIPHER_ID}', '${USER_A_FOLDER_ID}'),
('${USER_B_CIPHER_ID}', '${USER_B_FOLDER_ID}');

INSERT INTO sends (uuid, user_uuid, organization_uuid, name, notes, atype, data, akey, password_hash, password_salt, password_iter, max_access_count, access_count, creation_date, revision_date, expiration_date, deletion_date, disabled, hide_email) VALUES
('${SEND_A_ID}', '${USER_A_ID}', NULL, 'Niro Public Send A', 'Public send owned by Niro User A', 0, '{"Text":"Niro public send fixture","Hidden":false}', 'niro-send-a-key', NULL, NULL, NULL, NULL, 0, '${NOW}', '${NOW}', NULL, '${FUTURE}', 0, 0);
SQL

cat > "${NIRO_DIR}/credentials.yaml" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/credentials.json
credentials:
  - credential_id: STANDARD_USER_A
    description: "Vaultwarden standard user A. Owns only fixture user_a_private_cipher and user_a_public_send. Login: POST /identity/connect/token form grant_type=password, client_id=web, scope='api offline_access', username=identifier, password=secret, device_identifier=<stable test device>, device_name=niro, device_type=9. The secret is the Bitwarden masterPasswordHash value expected by Vaultwarden, not the raw master password. Pair with STANDARD_USER_B for horizontal authorization tests."
    type: username_password
    identifier: ${USER_A_EMAIL}
    secret: ${USER_A_SECRET}
  - credential_id: STANDARD_USER_B
    description: "Vaultwarden standard user B. Owns only fixture user_b_private_cipher and belongs to separate Niro Org B. Login shape is the same as STANDARD_USER_A; the secret is the masterPasswordHash value. Pair with STANDARD_USER_A for cross-user vault, folder, cipher, and Send isolation tests."
    type: username_password
    identifier: ${USER_B_EMAIL}
    secret: ${USER_B_SECRET}
  - credential_id: ORG_OWNER_A
    description: "Vaultwarden organization owner for Niro Org A. Confirmed membership type Owner (atype 0), access_all=true for org_a, owns administrative organization surfaces. Login shape is the same as STANDARD_USER_A; the secret is the masterPasswordHash value. Pair with ORG_MEMBER_A to verify standard org member denial on owner/admin endpoints."
    type: username_password
    identifier: ${OWNER_EMAIL}
    secret: ${OWNER_SECRET}
  - credential_id: ORG_MEMBER_A
    description: "Vaultwarden organization member for Niro Org A. Confirmed membership type User (atype 2), access_all=false, no collection grants. Login shape is the same as STANDARD_USER_A; the secret is the masterPasswordHash value. Use for vertical escalation tests against org owner/admin-only routes."
    type: username_password
    identifier: ${MEMBER_EMAIL}
    secret: ${MEMBER_SECRET}
  - credential_id: ADMIN_PANEL
    description: "Vaultwarden local admin-panel token. Authenticate by POST /admin with application/x-www-form-urlencoded body token=<secret>; successful login sets the VW_ADMIN cookie for /admin JSON and HTML admin endpoints. This is an instance-admin capability, separate from vault user roles."
    type: static_token
    secret: ${ADMIN_TOKEN_VALUE}
EOF

cat > "${NIRO_DIR}/fixtures.yaml" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/fixtures.json
fixtures:
  - name: target
    description: "Niro-managed Vaultwarden target built from the current checkout."
    value:
      base_url: ${TARGET_URL}
      health_url: ${TARGET_URL}/alive
      database_url: ${DATABASE_URL}
  - name: users
    description: "Deterministic dedicated test users and their effective privilege context."
    value:
      standard_user_a:
        uuid: ${USER_A_ID}
        email: ${USER_A_EMAIL}
        owns_cipher: ${USER_A_CIPHER_ID}
        owns_folder: ${USER_A_FOLDER_ID}
        owns_send: ${SEND_A_ID}
      standard_user_b:
        uuid: ${USER_B_ID}
        email: ${USER_B_EMAIL}
        owns_cipher: ${USER_B_CIPHER_ID}
      org_owner_a:
        uuid: ${OWNER_ID}
        email: ${OWNER_EMAIL}
        org_uuid: ${ORG_A_ID}
        membership_uuid: ${OWNER_MEMBERSHIP_ID}
        membership_type: owner
        access_all: true
      org_member_a:
        uuid: ${MEMBER_ID}
        email: ${MEMBER_EMAIL}
        org_uuid: ${ORG_A_ID}
        membership_uuid: ${MEMBER_MEMBERSHIP_ID}
        membership_type: user
        access_all: false
  - name: organizations
    description: "Deterministic organizations for same-org and cross-org authorization tests."
    value:
      org_a:
        uuid: ${ORG_A_ID}
        name: Niro Org A
        owner_membership_uuid: ${OWNER_MEMBERSHIP_ID}
        member_membership_uuid: ${MEMBER_MEMBERSHIP_ID}
        shared_cipher_uuid: ${ORG_A_CIPHER_ID}
      org_b:
        uuid: ${ORG_B_ID}
        name: Niro Org B
        shared_cipher_uuid: ${ORG_B_CIPHER_ID}
  - name: ciphers
    description: "Private and organization cipher IDs for authorization probes."
    value:
      user_a_private_cipher: ${USER_A_CIPHER_ID}
      user_b_private_cipher: ${USER_B_CIPHER_ID}
      org_a_shared_cipher: ${ORG_A_CIPHER_ID}
      org_b_shared_cipher: ${ORG_B_CIPHER_ID}
  - name: public_send
    description: "Public Send fixture owned by Standard User A."
    value:
      uuid: ${SEND_A_ID}
      access_url: ${TARGET_URL}/send/${SEND_A_ID}
EOF

for cred in STANDARD_USER_A STANDARD_USER_B ORG_OWNER_A ORG_MEMBER_A; do
  email="$(yq_email=''; case "${cred}" in STANDARD_USER_A) echo "${USER_A_EMAIL}";; STANDARD_USER_B) echo "${USER_B_EMAIL}";; ORG_OWNER_A) echo "${OWNER_EMAIL}";; ORG_MEMBER_A) echo "${MEMBER_EMAIL}";; esac)"
  secret="$(case "${cred}" in STANDARD_USER_A) echo "${USER_A_SECRET}";; STANDARD_USER_B) echo "${USER_B_SECRET}";; ORG_OWNER_A) echo "${OWNER_SECRET}";; ORG_MEMBER_A) echo "${MEMBER_SECRET}";; esac)"
  status="$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${TARGET_URL}/identity/connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=web" \
    --data-urlencode "scope=api offline_access" \
    --data-urlencode "username=${email}" \
    --data-urlencode "password=${secret}" \
    --data-urlencode "device_identifier=niro-${cred}" \
    --data-urlencode "device_name=Niro Harness" \
    --data-urlencode "device_type=9")"
  if [[ "${status}" != "200" ]]; then
    echo "Login verification failed for ${cred}: HTTP ${status}" >&2
    exit 1
  fi
done

echo "Seeded Vaultwarden Niro fixtures at ${TARGET_URL}"
