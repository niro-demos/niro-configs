#!/usr/bin/env bash
# Seed a deterministic baseline into the running Dify instance and emit
# ../credentials.yaml and ../fixtures.yaml describing it.
#
# Creates, across two tenants (workspaces) so cross-tenant isolation is
# testable, not just same-tenant role checks:
#
#   Tenant A (created via the one-time /console/api/setup bootstrap):
#     - owner-a    (owner)   -- also enables/holds the Service API key below
#     - admin-a    (admin)   -- vertical-escalation counterpart
#     - member-a1  (normal)  -- owns NO resources. Dify's "normal" role has
#                               no create/edit permission (models/account.py
#                               Account.has_edit_permission /
#                               is_dataset_editor require owner/admin/editor);
#                               kept specifically to verify dataset/app
#                               creation and admin-only surfaces correctly
#                               reject a plain member.
#     - editor-a1  (editor)  -- owns dataset-a1 + app-a1 (editor is the
#                               lowest role that can create/own resources)
#     - editor-a2  (editor)  -- owns dataset-a2 + app-a2 (different resources
#                               from editor-a1, for horizontal-escalation
#                               testing between same-role peers)
#   Tenant B (created via `flask create-tenant`, fully separate workspace):
#     - owner-b   (owner)   -- owns dataset-b + app-b, for cross-tenant
#                              isolation testing against Tenant A
#
# Member accounts are provisioned the way a real invited user would be
# (POST .../members/invite-email -> the invite response's activation token,
# same as the emailed link would carry -> POST /console/api/activate), then
# given a known password with the project's own `flask reset-password` CLI
# (api/commands/account.py) since the activation endpoint itself does not
# accept a password. Tenant B's owner is created directly with
# `flask create-tenant`, the project's own CLI for a second tenant.
#
# Re-running this script is safe: each step checks for existing state
# (setup already done, member already invited/activated, dataset/app already
# present by name) before creating anything.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=support/common.sh
source ./support/common.sh

require_cmd curl
require_cmd jq
require_cmd uv
require_cmd base64

wait_for_http "$API_URL/health" 60 || die "API is not reachable at $API_URL/health -- run ./start.sh first."

TMP_DIR="$RUN_DIR/tmp"
mkdir -p "$TMP_DIR"

# --- Fixed, deterministic test identities -------------------------------
OWNER_A_EMAIL="niro-owner-a@dify.local"
OWNER_A_NAME="Niro Owner A"
OWNER_A_PASSWORD="Niro-OwnerA-2026"

ADMIN_A_EMAIL="niro-admin-a@dify.local"
ADMIN_A_NAME="Niro Admin A"
ADMIN_A_PASSWORD="Niro-AdminA-2026"

MEMBER_A1_EMAIL="niro-member-a1@dify.local"
MEMBER_A1_NAME="Niro Member A1"
MEMBER_A1_PASSWORD="Niro-MemberA1-2026"

EDITOR_A1_EMAIL="niro-editor-a1@dify.local"
EDITOR_A1_NAME="Niro Editor A1"
EDITOR_A1_PASSWORD="Niro-EditorA1-2026"

EDITOR_A2_EMAIL="niro-editor-a2@dify.local"
EDITOR_A2_NAME="Niro Editor A2"
EDITOR_A2_PASSWORD="Niro-EditorA2-2026"

OWNER_B_EMAIL="niro-owner-b@dify.local"
OWNER_B_WORKSPACE_NAME="Niro Tenant B"
OWNER_B_PASSWORD=""  # captured from `flask create-tenant` output below

KNOWLEDGE_SOURCE_FILE="$FIXTURES_DIR/knowledge-source.txt"

# --- HTTP / auth helpers -------------------------------------------------

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

json_field() { # json_field <json> [jq options/--arg pairs...] <jq filter>
  local json="$1"
  shift
  printf '%s' "$json" | jq -r "$@"
}

url_encode() { jq -rn --arg v "$1" '$v|@uri'; }

# login <slug> <email> <password>
# Populates $COOKIE_DIR/<slug>.txt with the session (access_token,
# refresh_token, csrf_token) cookies. Password field is base64-encoded per
# controllers/console/wraps.py::decrypt_password_field.
login() {
  local slug="$1" email="$2" password="$3" jar body resp result
  jar="$COOKIE_DIR/${slug}.txt"
  rm -f "$jar"
  body="$(jq -n --arg email "$email" --arg password "$(b64 "$password")" \
    '{email: $email, password: $password, remember_me: true}')"
  resp="$(curl -sS -c "$jar" -H 'Content-Type: application/json' -d "$body" "$API_URL/console/api/login")"
  result="$(json_field "$resp" '.result // empty')"
  if [ "$result" != "success" ]; then
    log "Login failed for $email ($slug): $resp"
    return 1
  fi
}

csrf_of() {
  awk -F'\t' '$6=="csrf_token"{print $7}' "$COOKIE_DIR/${1}.txt" 2>/dev/null
}

# console_api <slug> <METHOD> <path> [json-body]
console_api() {
  local slug="$1" method="$2" path="$3" data="${4:-}" jar csrf
  jar="$COOKIE_DIR/${slug}.txt"
  csrf="$(csrf_of "$slug")"
  if [ -n "$data" ]; then
    curl -sS -b "$jar" -c "$jar" -X "$method" \
      -H 'Content-Type: application/json' -H "X-CSRF-Token: $csrf" \
      -d "$data" "$API_URL${path}"
  else
    curl -sS -b "$jar" -c "$jar" -X "$method" -H "X-CSRF-Token: $csrf" "$API_URL${path}"
  fi
}

console_api_upload() { # console_api_upload <slug> <path> <filepath>
  local slug="$1" path="$2" filepath="$3" jar csrf
  jar="$COOKIE_DIR/${slug}.txt"
  csrf="$(csrf_of "$slug")"
  curl -sS -b "$jar" -c "$jar" -H "X-CSRF-Token: $csrf" \
    -F "file=@${filepath};type=text/plain" "$API_URL${path}"
}

# --- Onboarding helpers ---------------------------------------------------

setup_owner_a() {
  local status
  status="$(curl -sS "$API_URL/console/api/setup" | jq -r '.step // empty')"
  if [ "$status" = "finished" ]; then
    log "System setup already completed; reusing existing first tenant/owner."
    return 0
  fi
  log "Bootstrapping system setup as $OWNER_A_EMAIL..."
  local body resp
  body="$(jq -n --arg email "$OWNER_A_EMAIL" --arg name "$OWNER_A_NAME" \
    --arg password "$OWNER_A_PASSWORD" --arg language "en-US" \
    '{email: $email, name: $name, password: $password, language: $language}')"
  resp="$(curl -sS -X POST -H 'Content-Type: application/json' -d "$body" "$API_URL/console/api/setup")"
  [ "$(json_field "$resp" '.result // empty')" = "success" ] || die "Setup failed: $resp"
}

# invite_member <owner_slug> <email> <role>
# Echoes the activation token (empty if the account is already an active
# member -- nothing further to do for it).
invite_member() {
  local owner_slug="$1" email="$2" role="$3" body resp url status
  body="$(jq -n --arg email "$email" --arg role "$role" \
    '{emails: [$email], role: $role, language: "en-US"}')"
  resp="$(console_api "$owner_slug" POST /console/api/workspaces/current/members/invite-email "$body")"
  status="$(json_field "$resp" '.invitation_results[0].status // empty')"
  if [ "$status" != "success" ]; then
    log "  (invite for $email: $status -- treating as already provisioned)"
    return 0
  fi
  url="$(json_field "$resp" '.invitation_results[0].url // empty')"
  printf '%s' "$url" | sed -n 's/.*[?&]token=\([^&]*\).*/\1/p'
}

activate_member() {
  local email="$1" token="$2" name="$3" resp
  resp="$(curl -sS -X POST -H 'Content-Type: application/json' \
    -d "$(jq -n --arg email "$email" --arg token "$token" --arg name "$name" \
      --arg lang "en-US" --arg tz "UTC" \
      '{email: $email, token: $token, name: $name, interface_language: $lang, timezone: $tz}')" \
    "$API_URL/console/api/activate")"
  [ "$(json_field "$resp" '.result // empty')" = "success" ] || log "  activate($email) response: $resp"
}

reset_password_cli() {
  local email="$1" password="$2"
  flask_cli reset-password --email "$email" --new-password "$password" --password-confirm "$password" \
    >"$TMP_DIR/reset-password-${email}.log" 2>&1 || {
    log "flask reset-password failed for $email; see $TMP_DIR/reset-password-${email}.log"
    tail -n 40 "$TMP_DIR/reset-password-${email}.log" >&2 || true
    return 1
  }
}

# verify_member_role <owner_slug> <email> <intended_role>
# invite_member's "already provisioned" idempotency path (when the invite
# call reports anything other than a fresh "success", e.g. "already exists")
# does not check the member's *current* role against the intended one -- so
# leftover state from an earlier, differently-configured seed run (or manual
# poking during harness iteration) can silently persist a wrong role across
# re-seeds. GET the workspace member list, and if the account's actual role
# doesn't match what this harness intends for it, correct it via PUT
# .../update-role (that endpoint only accepts PUT, not PATCH). Idempotent:
# a no-op when the role already matches.
verify_member_role() {
  local owner_slug="$1" email="$2" intended_role="$3" resp member_id actual_role update_resp result
  resp="$(console_api "$owner_slug" GET /console/api/workspaces/current/members)"
  member_id="$(json_field "$resp" --arg e "$email" '(.accounts // []) | map(select(.email == $e)) | .[0].id // empty')"
  actual_role="$(json_field "$resp" --arg e "$email" '(.accounts // []) | map(select(.email == $e)) | .[0].role // empty')"
  if [ -z "$member_id" ]; then
    log "  WARNING: could not find member $email in workspace member list to verify role."
    return 0
  fi
  if [ "$actual_role" = "$intended_role" ]; then
    log "  role check ok: $email is '$actual_role' as intended."
    return 0
  fi
  log "  role mismatch for $email: actual='$actual_role' intended='$intended_role' -- correcting via PUT update-role."
  update_resp="$(console_api "$owner_slug" PUT "/console/api/workspaces/current/members/${member_id}/update-role" \
    "$(jq -n --arg role "$intended_role" '{role: $role}')")"
  result="$(json_field "$update_resp" '.result // empty')"
  if [ "$result" != "success" ]; then
    log "  WARNING: failed to correct role for $email to '$intended_role': $update_resp"
  else
    log "  corrected $email role to '$intended_role'."
  fi
}

# provision_member <owner_slug> <email> <name> <role> <password>
# Invite (idempotent) -> activate (only if a fresh token was issued) ->
# known password -> verify (and correct, if needed) the resulting role.
provision_member() {
  local owner_slug="$1" email="$2" name="$3" role="$4" password="$5" token
  log "Provisioning $role member $email..."
  token="$(invite_member "$owner_slug" "$email" "$role")"
  if [ -n "$token" ]; then
    activate_member "$email" "$token" "$name"
  fi
  reset_password_cli "$email" "$password"
  verify_member_role "$owner_slug" "$email" "$role"
}

create_tenant_cli() { # create_tenant_cli <email> <workspace name> -> echoes password
  local email="$1" name="$2" out
  # `flask create-tenant` calls AccountService.create_account() and
  # TenantService.create_owner_tenant_if_not_exist() without is_setup=True,
  # which gate on FeatureService.is_allow_register / is_allow_create_workspace
  # (ALLOW_REGISTER / ALLOW_CREATE_WORKSPACE, both default false) regardless
  # of is_setup -- so the CLI itself needs both flags to run at all. Scoped
  # to only this one-off subprocess via an env prefix, not to the running
  # API/web processes' own env, so it does not open self-service HTTP
  # registration or workspace creation on the live target under test.
  out="$(ALLOW_REGISTER=true ALLOW_CREATE_WORKSPACE=true flask_cli create-tenant --email "$email" --name "$name" --language en-US 2>&1 \
    | sed -r 's/\x1b\[[0-9;]*m//g')"
  printf '%s\n' "$out" >"$TMP_DIR/create-tenant-${email}.log"
  if printf '%s' "$out" | grep -q '^Password: '; then
    printf '%s' "$out" | sed -n 's/^Password: //p' | tail -n1
  else
    log "flask create-tenant did not report a password for $email (may already exist): $out"
    printf ''
  fi
}

# --- Resource helpers (find-or-create, so re-seeding is idempotent) -------

find_dataset() { # find_dataset <slug> <name> -> id or empty
  local slug="$1" name="$2" resp
  resp="$(console_api "$slug" GET "/console/api/datasets?keyword=$(url_encode "$name")&page=1&limit=20")"
  json_field "$resp" --arg n "$name" '(.data // []) | map(select(.name == $n)) | .[0].id // empty'
}

create_dataset() { # create_dataset <slug> <name> -> id
  local slug="$1" name="$2" id resp
  id="$(find_dataset "$slug" "$name")"
  if [ -n "$id" ]; then
    log "  dataset '$name' already exists ($id)"
    printf '%s' "$id"
    return 0
  fi
  resp="$(console_api "$slug" POST /console/api/datasets \
    "$(jq -n --arg name "$name" '{name: $name, indexing_technique: "economy", permission: "only_me", provider: "vendor"}')")"
  id="$(json_field "$resp" '.id // empty')"
  [ -n "$id" ] || { log "  create_dataset($name) failed: $resp"; return 1; }
  log "  created dataset '$name' ($id)"
  printf '%s' "$id"
}

seed_dataset_document() { # seed_dataset_document <slug> <dataset_id>
  local slug="$1" dataset_id="$2" existing upload file_id resp
  existing="$(console_api "$slug" GET "/console/api/datasets/${dataset_id}/documents?page=1&limit=10" \
    | jq -r '(.data // []) | length')"
  if [ "${existing:-0}" -gt 0 ]; then
    log "  dataset $dataset_id already has documents"
    return 0
  fi
  upload="$(console_api_upload "$slug" /console/api/files/upload "$KNOWLEDGE_SOURCE_FILE")"
  file_id="$(json_field "$upload" '.id // empty')"
  [ -n "$file_id" ] || { log "  file upload failed: $upload"; return 1; }
  resp="$(console_api "$slug" POST "/console/api/datasets/${dataset_id}/documents" \
    "$(jq -n --arg fid "$file_id" '{
      data_source: {info_list: {data_source_type: "upload_file", file_info_list: {file_ids: [$fid]}}},
      doc_form: "text_model",
      doc_language: "English",
      indexing_technique: "economy",
      process_rule: {mode: "automatic"},
      retrieval_model: {reranking_enable: false, score_threshold_enabled: false, search_method: "keyword_search", top_k: 4}
    }')")"
  json_field "$resp" '.documents // .batch // "queued"' >/dev/null || true
  log "  queued knowledge document for dataset $dataset_id"
}

find_app() { # find_app <slug> <name> -> id or empty
  local slug="$1" name="$2" resp
  resp="$(console_api "$slug" GET "/console/api/apps?name=$(url_encode "$name")&mode=workflow&page=1&limit=20")"
  json_field "$resp" --arg n "$name" '(.data // []) | map(select(.name == $n)) | .[0].id // empty'
}

create_app() { # create_app <slug> <name> -> id
  local slug="$1" name="$2" id resp
  id="$(find_app "$slug" "$name")"
  if [ -n "$id" ]; then
    log "  app '$name' already exists ($id)"
    printf '%s' "$id"
    return 0
  fi
  resp="$(console_api "$slug" POST /console/api/apps \
    "$(jq -n --arg name "$name" --arg mode "workflow" --arg desc "Seeded by niro/harness/seed.sh for pentest coverage." \
      '{name: $name, mode: $mode, description: $desc}')")"
  id="$(json_field "$resp" '.id // empty')"
  [ -n "$id" ] || { log "  create_app($name) failed: $resp"; return 1; }
  log "  created app '$name' ($id)"
  printf '%s' "$id"
}

enable_app_api() { # enable_app_api <owner_slug> <app_id>
  console_api "$1" POST "/console/api/apps/${2}/api-enable" '{"enable_api": true}' >/dev/null
}

create_app_api_key() { # create_app_api_key <owner_slug> <app_id> -> token
  local slug="$1" app_id="$2" resp existing
  existing="$(console_api "$slug" GET "/console/api/apps/${app_id}/api-keys" | jq -r '(.data // [])[0].token // empty')"
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi
  resp="$(console_api "$slug" POST "/console/api/apps/${app_id}/api-keys" '')"
  json_field "$resp" '.token // empty'
}

current_tenant_id() { # current_tenant_id <slug>
  # TenantApi (controllers/console/workspace/workspace.py) only defines
  # .post for /console/api/workspaces/current -- GET is 405 there.
  console_api "$1" POST /console/api/workspaces/current | jq -r '.id // empty'
}

# =========================================================================
# Main
# =========================================================================

setup_owner_a
login owner_a "$OWNER_A_EMAIL" "$OWNER_A_PASSWORD" || die "Could not log in as $OWNER_A_EMAIL after setup."

provision_member owner_a "$ADMIN_A_EMAIL" "$ADMIN_A_NAME" admin "$ADMIN_A_PASSWORD"
provision_member owner_a "$MEMBER_A1_EMAIL" "$MEMBER_A1_NAME" normal "$MEMBER_A1_PASSWORD"
provision_member owner_a "$EDITOR_A1_EMAIL" "$EDITOR_A1_NAME" editor "$EDITOR_A1_PASSWORD"
provision_member owner_a "$EDITOR_A2_EMAIL" "$EDITOR_A2_NAME" editor "$EDITOR_A2_PASSWORD"

login admin_a "$ADMIN_A_EMAIL" "$ADMIN_A_PASSWORD" || die "Could not log in as $ADMIN_A_EMAIL."
login member_a1 "$MEMBER_A1_EMAIL" "$MEMBER_A1_PASSWORD" || die "Could not log in as $MEMBER_A1_EMAIL."
login editor_a1 "$EDITOR_A1_EMAIL" "$EDITOR_A1_PASSWORD" || die "Could not log in as $EDITOR_A1_EMAIL."
login editor_a2 "$EDITOR_A2_EMAIL" "$EDITOR_A2_PASSWORD" || die "Could not log in as $EDITOR_A2_EMAIL."

log "Confirming member-a1 (role: normal) is correctly denied dataset/app creation..."
member_a1_dataset_denied="$(console_api member_a1 POST /console/api/datasets \
  "$(jq -n --arg name "Niro Dataset (should be denied)" '{name: $name, indexing_technique: "economy", permission: "only_me", provider: "vendor"}')" \
  | jq -r '.status // empty')"
if [ "$member_a1_dataset_denied" = "403" ]; then
  log "  confirmed: normal role cannot create datasets (403), as expected."
else
  log "  WARNING: expected 403 denying member-a1 dataset creation, got status='${member_a1_dataset_denied:-<none>}'."
fi

log "Seeding Tenant A fixtures owned by editor-a1..."
DATASET_A1_ID="$(create_dataset editor_a1 "Niro Dataset A1")"
seed_dataset_document editor_a1 "$DATASET_A1_ID"
APP_A1_ID="$(create_app editor_a1 "Niro Workflow A1")"

log "Seeding Tenant A fixtures owned by editor-a2 (different resources, for horizontal-escalation tests)..."
DATASET_A2_ID="$(create_dataset editor_a2 "Niro Dataset A2")"
seed_dataset_document editor_a2 "$DATASET_A2_ID"
APP_A2_ID="$(create_app editor_a2 "Niro Workflow A2")"

log "Enabling the Service API and minting a key for app-a1 (as owner-a; api-enable is owner/admin-only)..."
enable_app_api owner_a "$APP_A1_ID"
APP_A1_SERVICE_API_KEY="$(create_app_api_key owner_a "$APP_A1_ID")"

# `flask create-tenant` has no existence check of its own -- email is not a
# unique/upsert key for it, so calling it a second time for the same email
# creates a SECOND, entirely separate account+tenant (confirmed empirically:
# no DB-level unique constraint stops it). Re-seeding must not call it again
# once Tenant B already exists, or it silently multiplies tenants. Guard
# with a login-based check first (cheap, no DB access needed) backed by a
# small local state marker recording the password this harness itself set;
# reset.sh wipes both the DB and this marker together so they can't drift.
OWNER_B_STATE_FILE="$STATE_DIR/owner-b.env"
OWNER_B_PASSWORD=""
if [ -f "$OWNER_B_STATE_FILE" ]; then
  # shellcheck disable=SC1090
  source "$OWNER_B_STATE_FILE"
  if ! login owner_b "$OWNER_B_EMAIL" "$OWNER_B_PASSWORD" 2>/dev/null; then
    OWNER_B_PASSWORD=""
  fi
fi

if [ -n "$OWNER_B_PASSWORD" ]; then
  log "Tenant B owner already provisioned; reusing recorded credentials."
else
  log "Creating Tenant B (separate workspace) via 'flask create-tenant'..."
  created_password="$(create_tenant_cli "$OWNER_B_EMAIL" "$OWNER_B_WORKSPACE_NAME")"
  if [ -z "$created_password" ]; then
    die "flask create-tenant did not create a new account for $OWNER_B_EMAIL, and no working recorded credentials were found in $OWNER_B_STATE_FILE. A stale account may already occupy this email without a usable/known password -- this harness will not guess at or overwrite an account it cannot already log into. Run ./reset.sh for a clean baseline, or inspect the account manually."
  fi
  OWNER_B_PASSWORD="Niro-OwnerB-2026"
  reset_password_cli "$OWNER_B_EMAIL" "$OWNER_B_PASSWORD"
  login owner_b "$OWNER_B_EMAIL" "$OWNER_B_PASSWORD" || die "Could not log in as $OWNER_B_EMAIL right after creating Tenant B."
  printf 'OWNER_B_PASSWORD=%q\n' "$OWNER_B_PASSWORD" >"$OWNER_B_STATE_FILE"
fi

log "Seeding Tenant B fixtures owned by owner-b (separate tenant, for cross-tenant isolation tests)..."
DATASET_B_ID="$(create_dataset owner_b "Niro Dataset B")"
seed_dataset_document owner_b "$DATASET_B_ID"
APP_B_ID="$(create_app owner_b "Niro Workflow B")"

TENANT_A_ID="$(current_tenant_id owner_a)"
TENANT_B_ID="$(current_tenant_id owner_b)"

# --- Write credentials.yaml (gitignored; real secrets) --------------------

cat >"$NIRO_DIR/credentials.yaml" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/credentials.json
#
# GENERATED by niro/harness/seed.sh -- do not edit by hand, re-run seed.sh
# instead. See niro/credentials.yaml.example for the format reference.

credentials:
  - description: "Tenant A owner (role: owner). Bootstrapped via the one-time
      POST /console/api/setup system install, so it is also the account that
      completed initial setup. Also holds the Service API key below (created
      via app-a1's api-enable + api-keys endpoints; those two endpoints are
      admin-or-owner, NOT owner-only -- admin-a can call them too, that is
      by design, not escalation). Login: POST /console/api/login with JSON
      body {email, password, remember_me} where password is base64-encoded
      (controllers/console/wraps.py::decrypt_password_field). On success the
      server sets three cookies -- access_token (httpOnly), refresh_token
      (httpOnly), csrf_token (NOT httpOnly) -- no tokens are returned in the
      JSON body. Every subsequent /console/api/* request (GET included) must
      send the access_token cookie AND an X-CSRF-Token header equal to the
      csrf_token cookie value (libs/token.py::check_csrf_token), except the
      workflow-draft-save route which is CSRF-exempt
      (/console/api/apps/<uuid>/workflows/draft). Authorization: Bearer
      <access_token> is also accepted in place of the cookie for the access
      token specifically, but the CSRF header/cookie pair is still required.
      Pair with admin-a for vertical-escalation tests against the small set
      of truly owner-only actions (e.g. owner transfer) and with owner-b to
      verify Tenant A/B data never cross."
    type: username_password
    identifier: ${OWNER_A_EMAIL}
    secret: "${OWNER_A_PASSWORD}"

  - description: "Tenant A admin (role: admin), same tenant as owner-a,
      member-a1, editor-a1, editor-a2. Invited via POST
      /console/api/workspaces/current/members/invite-email and activated via
      POST /console/api/activate, same login/CSRF flow as owner-a. Admin is
      intentionally near-equal to owner in this app: it can manage
      members/apps/datasets tenant-wide and call admin-or-owner endpoints
      such as .../api-enable (do not flag admin succeeding there as
      escalation). Admin should NOT be able to perform the few strictly
      owner-only actions gated by TenantService.is_owner (e.g. owner
      transfer). Use to verify member-a1 (role: normal) is rejected from
      admin-only surfaces, and that admin is itself rejected from
      owner-only surfaces."
    type: username_password
    identifier: ${ADMIN_A_EMAIL}
    secret: "${ADMIN_A_PASSWORD}"

  - description: "Tenant A standard member (role: normal). Owns NO
      resources on purpose: models/account.py Account.has_edit_permission /
      is_dataset_editor require owner/admin/editor, so a normal member's
      POST /console/api/datasets and POST /console/api/apps calls return 403
      by design -- this account exists to verify that denial holds (and that
      it cannot reach editor-a1/editor-a2/owner-a/admin-a's resources or any
      admin-only surface), not to own content. Same login/CSRF flow as
      owner-a."
    type: username_password
    identifier: ${MEMBER_A1_EMAIL}
    secret: "${MEMBER_A1_PASSWORD}"

  - description: "Tenant A editor (role: editor), same tenant as owner-a,
      admin-a, member-a1, editor-a2. Editor is the lowest role that can
      create/own resources (see member-a1's description for the permission
      check). Owns dataset-a1 (${DATASET_A1_ID}) and app-a1 (${APP_A1_ID}),
      an economy/keyword-search knowledge base and a draft workflow app it
      created itself. Same login/CSRF flow as owner-a. Pair with editor-a2
      for horizontal-escalation tests: authenticate as editor-a1, attempt to
      read/modify editor-a2's dataset/app, expect 403/404."
    type: username_password
    identifier: ${EDITOR_A1_EMAIL}
    secret: "${EDITOR_A1_PASSWORD}"

  - description: "Tenant A editor (role: editor), same tenant as editor-a1
      but owns different resources: dataset-a2 (${DATASET_A2_ID}) and app-a2
      (${APP_A2_ID}). Same login/CSRF flow as owner-a. Pair with editor-a1
      for horizontal-escalation tests."
    type: username_password
    identifier: ${EDITOR_A2_EMAIL}
    secret: "${EDITOR_A2_PASSWORD}"

  - description: "Tenant B owner (role: owner) in a wholly separate
      workspace/tenant from Tenant A, created directly via the project's
      'flask create-tenant' CLI rather than an invite. Owns dataset-b
      (${DATASET_B_ID}) and app-b (${APP_B_ID}). Same login/CSRF flow as
      owner-a. Use to verify NO account from Tenant A (owner-a, admin-a,
      member-a1, editor-a1, editor-a2) can read or modify Tenant B's
      workspace, members, datasets, or apps, and vice versa -- this is the
      primary cross-tenant isolation credential."
    type: username_password
    identifier: ${OWNER_B_EMAIL}
    secret: "${OWNER_B_PASSWORD}"
EOF

if [ -n "${APP_A1_SERVICE_API_KEY:-}" ]; then
  cat >>"$NIRO_DIR/credentials.yaml" <<EOF

  - description: "Service API key for app-a1 (${APP_A1_ID}, owned by
      editor-a1 in Tenant A), created via POST
      /console/api/apps/${APP_A1_ID}/api-keys after enabling the app's API
      with owner-a. Distinct auth surface from the console/browser session
      above: sent as 'Authorization: Bearer <token>' against the public
      Service API under /v1/* (e.g. /v1/workflows/run), not /console/api/*.
      Use to probe whether the Service API and console session code paths
      have consistent authorization -- a service key scoped to one app
      should not reach another app's or another tenant's resources."
    type: bearer_token
    secret: "Bearer ${APP_A1_SERVICE_API_KEY}"
EOF
fi

log "Wrote $NIRO_DIR/credentials.yaml"

# --- Write fixtures.yaml (gitignored; non-secret references) --------------

cat >"$NIRO_DIR/fixtures.yaml" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/fixtures.json
#
# GENERATED by niro/harness/seed.sh -- do not edit by hand, re-run seed.sh
# instead. See niro/fixtures.yaml.example for the format reference.

fixtures:
  - name: web_base_url
    description: "Frontend base URL this harness started (production build, served from web/ source). Use as the pentest base URL."
    value: ${WEB_URL}

  - name: api_base_url
    description: "Backend API base URL this harness started (Flask app run from api/ source). Console API is under /console/api/*, the public Service API is under /v1/*, health check at /health."
    value: ${API_URL}

  - name: tenant_a_id
    description: "Tenant A workspace id. owner-a, admin-a, member-a1, editor-a1, and editor-a2 all belong to this tenant."
    value: ${TENANT_A_ID}

  - name: tenant_b_id
    description: "Tenant B workspace id, fully separate from Tenant A. owner-b belongs only to this tenant. Use with tenant_a_id to test cross-tenant isolation."
    value: ${TENANT_B_ID}

  - name: dataset_a1
    description: "Knowledge base dataset owned by editor-a1 in Tenant A. Economy/keyword-search indexing (no embedding model required), one indexed document from niro/harness/fixtures/knowledge-source.txt containing the marker string 'niro-fixture-marker-alpha'."
    value:
      id: ${DATASET_A1_ID}
      owner: editor-a1
      tenant: tenant-a
      name: "Niro Dataset A1"

  - name: dataset_a2
    description: "Knowledge base dataset owned by editor-a2 in Tenant A, same shape as dataset_a1 but a distinct resource for horizontal-escalation testing between editor-a1 and editor-a2."
    value:
      id: ${DATASET_A2_ID}
      owner: editor-a2
      tenant: tenant-a
      name: "Niro Dataset A2"

  - name: dataset_b
    description: "Knowledge base dataset owned by owner-b in Tenant B, same shape as dataset_a1/a2 but in a separate tenant, for cross-tenant isolation testing."
    value:
      id: ${DATASET_B_ID}
      owner: owner-b
      tenant: tenant-b
      name: "Niro Dataset B"

  - name: app_a1
    description: "Draft workflow app owned by editor-a1 in Tenant A. Service API is enabled and the app-a1-service-api-key credential is scoped to it."
    value:
      id: ${APP_A1_ID}
      owner: editor-a1
      tenant: tenant-a
      mode: workflow
      name: "Niro Workflow A1"
      service_api_enabled: true

  - name: app_a2
    description: "Draft workflow app owned by editor-a2 in Tenant A, a distinct resource from app_a1 for horizontal-escalation testing."
    value:
      id: ${APP_A2_ID}
      owner: editor-a2
      tenant: tenant-a
      mode: workflow
      name: "Niro Workflow A2"
      service_api_enabled: false

  - name: app_b
    description: "Draft workflow app owned by owner-b in Tenant B, for cross-tenant isolation testing against app_a1/app_a2."
    value:
      id: ${APP_B_ID}
      owner: owner-b
      tenant: tenant-b
      mode: workflow
      name: "Niro Workflow B"
      service_api_enabled: false

  - name: knowledge_source_marker
    description: "Distinctive string present in the one indexed document seeded into every dataset above (dataset_a1, dataset_a2, dataset_b). Use to confirm a retrieval/search response actually came from the expected dataset and not a leaked cross-tenant/cross-user one."
    value: niro-fixture-marker-alpha
EOF

log "Wrote $NIRO_DIR/fixtures.yaml"
log "Seed complete."
