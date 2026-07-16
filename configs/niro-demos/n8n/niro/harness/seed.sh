#!/usr/bin/env bash
# Deterministic baseline for the Niro-owned n8n target.
#
# Creates (or reconciles, if a previous seed already ran without a reset):
#   - an instance owner (global:owner)
#   - two standard members in SEPARATE personal projects, each owning a
#     credential + workflow (for horizontal-escalation testing)
#   - a personal-access API key for the owner (public API / REST cross-check)
#   - one workflow + one credential per user (for authz surface testing)
#
# Emits ../credentials.yaml and ../fixtures.yaml. Idempotent: safe to re-run
# against an already-seeded instance (reuses existing users/resources by
# stable name instead of duplicating them).
#
# NOTE: inviting a global:admin user is blocked on this build — n8n gates
# that role behind the paid "Advanced Permissions" license feature, which
# has no activation key in this environment. See ../accepted-coverage-gaps.yaml.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

"$HARNESS_DIR/start.sh"

BASE="$N8N_BASE_URL"
COOKIE_DIR="$RUN_DIR/cookies"
mkdir -p "$COOKIE_DIR"
OWNER_JAR="$COOKIE_DIR/owner.jar"
MEMBER_A_JAR="$COOKIE_DIR/member-a.jar"
MEMBER_B_JAR="$COOKIE_DIR/member-b.jar"
rm -f "$OWNER_JAR" "$MEMBER_A_JAR" "$MEMBER_B_JAR"

OWNER_EMAIL="owner@niro.n8n.local"
OWNER_PASSWORD="NiroOwner123!"
MEMBER_A_EMAIL="member-a@niro.n8n.local"
MEMBER_A_PASSWORD="NiroMemberA123!"
MEMBER_B_EMAIL="member-b@niro.n8n.local"
MEMBER_B_PASSWORD="NiroMemberB123!"

api_get() { curl -sS -b "$2" -X GET "$BASE$1"; }
api_post() { curl -sS -b "$2" -c "$2" -H "Content-Type: application/json" -X POST "$BASE$1" -d "$3"; }
api_delete() { curl -sS -b "$2" -X DELETE "$BASE$1"; }

login() {
	local email="$1" password="$2" jar="$3"
	curl -sS -c "$jar" -H "Content-Type: application/json" -X POST "$BASE/rest/login" \
		-d "$(jq -nc --arg e "$email" --arg p "$password" '{emailOrLdapLoginId:$e,password:$p}')"
}

echo "== Owner =="
setup_resp=$(curl -sS -c "$OWNER_JAR" -H "Content-Type: application/json" -X POST "$BASE/rest/owner/setup" \
	-d "$(jq -nc --arg e "$OWNER_EMAIL" --arg p "$OWNER_PASSWORD" \
		'{email:$e,firstName:"Niro",lastName:"Owner",password:$p}')")
if echo "$setup_resp" | jq -e '.code == 400' >/dev/null 2>&1; then
	echo "Owner already set up; logging in instead."
	login "$OWNER_EMAIL" "$OWNER_PASSWORD" "$OWNER_JAR" >/dev/null
fi
OWNER_ID=$(api_get /rest/login "$OWNER_JAR" 2>/dev/null | jq -r '.data.id // empty')
if [[ -z "$OWNER_ID" ]]; then
	# /rest/login GET resolves the current session; fall back to explicit login.
	OWNER_ID=$(login "$OWNER_EMAIL" "$OWNER_PASSWORD" "$OWNER_JAR" | jq -r '.data.id')
fi
echo "Owner id: $OWNER_ID"

invite_or_login() {
	local email="$1" password="$2" first="$3" last="$4" role="$5" jar="$6"
	local invite_resp token
	invite_resp=$(api_post /rest/invitations "$OWNER_JAR" \
		"$(jq -nc --arg e "$email" --arg r "$role" '[{email:$e,role:$r}]')")
	token=$(echo "$invite_resp" | jq -r '.data[0].user.inviteAcceptUrl // empty' | sed -n 's/.*token=//p')
	if [[ -n "$token" ]]; then
		curl -sS -c "$jar" -H "Content-Type: application/json" -X POST "$BASE/rest/invitations/accept" \
			-d "$(jq -nc --arg t "$token" --arg f "$first" --arg l "$last" --arg p "$password" \
				'{token:$t,firstName:$f,lastName:$l,password:$p}')" >/dev/null
	else
		login "$email" "$password" "$jar" >/dev/null
	fi
}

echo "== Member A (horizontal-escalation pair #1) =="
invite_or_login "$MEMBER_A_EMAIL" "$MEMBER_A_PASSWORD" "Niro" "MemberA" "global:member" "$MEMBER_A_JAR"
MEMBER_A_ID=$(login "$MEMBER_A_EMAIL" "$MEMBER_A_PASSWORD" "$MEMBER_A_JAR" | jq -r '.data.id')
echo "Member A id: $MEMBER_A_ID"

echo "== Member B (horizontal-escalation pair #2, separate resources) =="
invite_or_login "$MEMBER_B_EMAIL" "$MEMBER_B_PASSWORD" "Niro" "MemberB" "global:member" "$MEMBER_B_JAR"
MEMBER_B_ID=$(login "$MEMBER_B_EMAIL" "$MEMBER_B_PASSWORD" "$MEMBER_B_JAR" | jq -r '.data.id')
echo "Member B id: $MEMBER_B_ID"

echo "== Admin (vertical-escalation) — expected to be license-gated =="
admin_resp=$(api_post /rest/invitations "$OWNER_JAR" \
	'[{"email":"admin@niro.n8n.local","role":"global:admin"}]')
if echo "$admin_resp" | jq -e '.code == 403' >/dev/null 2>&1; then
	echo "Confirmed: global:admin invite is blocked (Advanced Permissions is a paid, unlicensed feature here)."
else
	echo "WARNING: global:admin invite unexpectedly succeeded — update accepted-coverage-gaps.yaml and add a GLOBAL_ADMIN credential." >&2
fi

# --- credential + workflow per user, reused by name if already seeded ---

ensure_credential() {
	local jar="$1" name="$2" type="$3" data_json="$4"
	local existing
	existing=$(api_get /rest/credentials "$jar" | jq -r --arg n "$name" '.data[] | select(.name==$n) | .id' | head -1)
	if [[ -n "$existing" ]]; then
		echo "$existing"
		return
	fi
	api_post /rest/credentials "$jar" \
		"$(jq -nc --arg n "$name" --arg t "$type" --argjson d "$data_json" '{name:$n,type:$t,data:$d}')" \
		| jq -r '.data.id'
}

ensure_workflow() {
	local jar="$1" name="$2" node_id="$3"
	local existing
	existing=$(api_get /rest/workflows "$jar" | jq -r --arg n "$name" '.data[] | select(.name==$n) | .id' | head -1)
	if [[ -n "$existing" ]]; then
		echo "$existing"
		return
	fi
	api_post /rest/workflows "$jar" "$(jq -nc --arg n "$name" --arg id "$node_id" '{
		name: $n,
		nodes: [{
			id: $id,
			name: "When clicking Test workflow",
			type: "n8n-nodes-base.manualTrigger",
			typeVersion: 1,
			position: [250, 300],
			parameters: {}
		}],
		connections: {},
		settings: {}
	}')" | jq -r '.data.id'
}

echo "== Fixtures: credentials + workflows =="
OWNER_CRED_ID=$(ensure_credential "$OWNER_JAR" "Owner Header Credential" "httpHeaderAuth" '{"name":"X-Niro-Owner","value":"owner-secret-value"}')
OWNER_WF_ID=$(ensure_workflow "$OWNER_JAR" "Niro Owner Workflow" "11111111-1111-1111-1111-111111111111")

MEMBER_A_CRED_ID=$(ensure_credential "$MEMBER_A_JAR" "Member A Header Credential" "httpHeaderAuth" '{"name":"X-Niro-Member-A","value":"member-a-secret-value"}')
MEMBER_A_WF_ID=$(ensure_workflow "$MEMBER_A_JAR" "Niro Member A Workflow" "22222222-2222-2222-2222-222222222222")

MEMBER_B_CRED_ID=$(ensure_credential "$MEMBER_B_JAR" "Member B Header Credential" "httpHeaderAuth" '{"name":"X-Niro-Member-B","value":"member-b-secret-value"}')
MEMBER_B_WF_ID=$(ensure_workflow "$MEMBER_B_JAR" "Niro Member B Workflow" "33333333-3333-3333-3333-333333333333")

echo "== Owner public-API key (delete+recreate for idempotency; raw value only returned once) =="
existing_key_id=$(api_get /rest/api-keys "$OWNER_JAR" | jq -r '.data.items[] | select(.label=="Niro Owner API Key") | .id' | head -1)
if [[ -n "$existing_key_id" ]]; then
	api_delete "/rest/api-keys/$existing_key_id" "$OWNER_JAR" >/dev/null
fi
api_key_resp=$(api_post /rest/api-keys "$OWNER_JAR" '{
	"label": "Niro Owner API Key",
	"expiresAt": null,
	"scopes": ["workflow:list","workflow:read","workflow:create","workflow:update","workflow:delete",
	           "credential:list","credential:read","credential:create","credential:update","credential:delete",
	           "user:list","user:read"]
}')
OWNER_API_KEY=$(echo "$api_key_resp" | jq -r '.data.rawApiKey')

echo "== Writing credentials.yaml and fixtures.yaml =="

cat > "$NIRO_DIR/credentials.yaml" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/credentials.json
# GENERATED by niro/harness/seed.sh — do not edit by hand. Re-run seed.sh to
# regenerate. See niro/credentials.yaml.example for the format reference.
credentials:
  - credential_id: OWNER
    description: "Instance owner (role global:owner) — full instance admin,
      superset of global:admin. Login: POST /rest/login with body
      {emailOrLdapLoginId, password}; sets an n8n-auth session cookie. Owns
      the 'Niro Owner Workflow' workflow and 'Owner Header Credential'
      credential in their personal project. Pair with MEMBER_A / MEMBER_B
      for vertical-escalation checks: standard members must be denied at
      owner/admin-only surfaces (user management, API-key management,
      instance settings, /rest/owner/*, /rest/ldap/*, /rest/saml/*, license
      management)."
    type: username_password
    identifier: $OWNER_EMAIL
    secret: "$OWNER_PASSWORD"

  - credential_id: MEMBER_A
    description: "Standard member (role global:member), horizontal-escalation
      pair A. Login: POST /rest/login with body {emailOrLdapLoginId,
      password}. Owns 'Niro Member A Workflow' (id $MEMBER_A_WF_ID) and
      'Member A Header Credential' (id $MEMBER_A_CRED_ID) in their OWN
      personal project — separate from Member B's resources. Pair with
      MEMBER_B: authenticate as A, attempt to read/modify/execute B's
      workflow or credential by id, expect 403/404. No admin or instance-wide
      capability beyond the global:member role."
    type: username_password
    identifier: $MEMBER_A_EMAIL
    secret: "$MEMBER_A_PASSWORD"

  - credential_id: MEMBER_B
    description: "Standard member (role global:member), horizontal-escalation
      pair B. Login: same shape as Member A. Owns 'Niro Member B Workflow'
      (id $MEMBER_B_WF_ID) and 'Member B Header Credential' (id
      $MEMBER_B_CRED_ID) in their OWN personal project — different resources
      from Member A so cross-user access attempts have something to fail at.
      No admin or instance-wide capability beyond the global:member role."
    type: username_password
    identifier: $MEMBER_B_EMAIL
    secret: "$MEMBER_B_PASSWORD"

  - credential_id: OWNER_API_KEY
    description: "Public/REST API key for the OWNER principal (same user and
      privilege as the OWNER credential above, different auth surface). Send
      as header X-N8N-API-KEY (header:X-N8N-API-KEY). Scoped to
      workflow:*/credential:*/user:read/list. Use to probe whether the
      cookie-session and API-key code paths enforce the same authorization
      (a bug class where one auth surface is less strict than the other)."
    type: static_token
    secret: "$OWNER_API_KEY"
EOF

cat > "$NIRO_DIR/fixtures.yaml" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/fixtures.json
# GENERATED by niro/harness/seed.sh — do not edit by hand. Re-run seed.sh to
# regenerate. See niro/fixtures.yaml.example for the format reference.
fixtures:
  - name: base_url
    description: "Base URL of the Niro-managed n8n instance (editor UI + REST API + public API all served from this origin)."
    value: "$N8N_BASE_URL"

  - name: rest_api_base_path
    description: "Internal REST API used by the editor UI. Cookie-authenticated (n8n-auth). Prefix all internal endpoints with this path, e.g. $N8N_BASE_URL/rest/workflows."
    value: "/rest"

  - name: public_api_base_path
    description: "Public API, versioned, key-authenticated via the OWNER_API_KEY credential (header X-N8N-API-KEY). E.g. $N8N_BASE_URL/api/v1/workflows."
    value: "/api/v1"

  - name: owner_user
    description: "Instance owner seeded by seed.sh. Pair with the OWNER credential."
    value:
      id: "$OWNER_ID"
      email: "$OWNER_EMAIL"
      role: "global:owner"

  - name: owner_workflow
    description: "Workflow owned by OWNER in their personal project. A single manual-trigger node, inactive."
    value:
      id: "$OWNER_WF_ID"
      name: "Niro Owner Workflow"
      owner_credential_id: OWNER

  - name: owner_credential
    description: "httpHeaderAuth credential owned by OWNER in their personal project. Credential VALUES are never exposed via the API (only metadata) — use this id to probe read/update/delete authorization, not to recover the secret."
    value:
      id: "$OWNER_CRED_ID"
      name: "Owner Header Credential"
      type: "httpHeaderAuth"

  - name: member_a_user
    description: "Standard member seeded by seed.sh. Pair with the MEMBER_A credential."
    value:
      id: "$MEMBER_A_ID"
      email: "$MEMBER_A_EMAIL"
      role: "global:member"

  - name: member_a_workflow
    description: "Workflow owned by MEMBER_A in their OWN personal project (not shared with MEMBER_B or OWNER). Use for horizontal-escalation checks: MEMBER_B must not be able to read/update/execute/delete this via /rest/workflows/$MEMBER_A_WF_ID or /api/v1/workflows/$MEMBER_A_WF_ID."
    value:
      id: "$MEMBER_A_WF_ID"
      name: "Niro Member A Workflow"
      owner_credential_id: MEMBER_A

  - name: member_a_credential
    description: "httpHeaderAuth credential owned by MEMBER_A. Use for horizontal-escalation checks against MEMBER_B (id/metadata read, not secret recovery — n8n never returns decrypted credential data over the API)."
    value:
      id: "$MEMBER_A_CRED_ID"
      name: "Member A Header Credential"
      type: "httpHeaderAuth"

  - name: member_b_user
    description: "Standard member seeded by seed.sh. Pair with the MEMBER_B credential."
    value:
      id: "$MEMBER_B_ID"
      email: "$MEMBER_B_EMAIL"
      role: "global:member"

  - name: member_b_workflow
    description: "Workflow owned by MEMBER_B in their OWN personal project (not shared with MEMBER_A or OWNER). Use for horizontal-escalation checks: MEMBER_A must not be able to read/update/execute/delete this via /rest/workflows/$MEMBER_B_WF_ID or /api/v1/workflows/$MEMBER_B_WF_ID."
    value:
      id: "$MEMBER_B_WF_ID"
      name: "Niro Member B Workflow"
      owner_credential_id: MEMBER_B

  - name: member_b_credential
    description: "httpHeaderAuth credential owned by MEMBER_B. Use for horizontal-escalation checks against MEMBER_A."
    value:
      id: "$MEMBER_B_CRED_ID"
      name: "Member B Header Credential"
      type: "httpHeaderAuth"

  - name: global_admin_role
    description: "The global:admin role exists in the RBAC model but could not be seeded here: inviting a global:admin user requires the paid 'Advanced Permissions' license feature, which has no activation key in this environment (POST /rest/invitations with role=global:admin returns 403). See accepted-coverage-gaps.yaml. OWNER already covers every surface global:admin would additionally unlock over global:member, so vertical-escalation coverage for member-vs-owner is intact; only member-vs-admin-specifically is unverified."
    value: null
EOF

echo "Seed complete."
echo "  base_url: $N8N_BASE_URL"
echo "  credentials.yaml: $NIRO_DIR/credentials.yaml"
echo "  fixtures.yaml: $NIRO_DIR/fixtures.yaml"
