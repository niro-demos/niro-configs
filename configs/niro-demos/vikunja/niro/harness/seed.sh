#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NIRO_DIR="$ROOT_DIR/niro"
RUN_DIR="$NIRO_DIR/harness/run"
API_BASE="${VIKUNJA_NIRO_API_BASE:-http://127.0.0.1:${VIKUNJA_NIRO_API_PORT:-3456}}"
FRONTEND_BASE="${VIKUNJA_NIRO_FRONTEND_BASE:-http://localhost:${VIKUNJA_NIRO_FRONTEND_PORT:-4173}}"
TESTING_TOKEN="${VIKUNJA_NIRO_TESTING_TOKEN:-niro-local-testing-token}"

api() {
	local method="$1"
	local path="$2"
	local body="${3:-}"
	local token="${4:-}"
	local args=(-fsS -X "$method" "$API_BASE/api/v1$path" -H "Content-Type: application/json")
	if [[ -n "$token" ]]; then
		args+=(-H "Authorization: Bearer $token")
	fi
	if [[ -n "$body" ]]; then
		args+=(-d "$body")
	fi
	curl "${args[@]}"
}

wait_for_api() {
	local deadline=$((SECONDS + 60))
	while (( SECONDS < deadline )); do
		if curl -fsS "$API_BASE/api/v1/info" >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	echo "API is not reachable at $API_BASE" >&2
	return 1
}

json_string() {
	jq -Rn --arg value "$1" '$value'
}

register_user() {
	local username="$1"
	local email="$2"
	local password="$3"
	api POST /register "{\"username\":$(json_string "$username"),\"email\":$(json_string "$email"),\"password\":$(json_string "$password"),\"language\":\"en\"}" >/dev/null
}

login_user() {
	local username="$1"
	local password="$2"
	api POST /login "{\"username\":$(json_string "$username"),\"password\":$(json_string "$password"),\"long_token\":true}" | jq -r '.token'
}

create_project() {
	local token="$1"
	local title="$2"
	local identifier="$3"
	local color="$4"
	api PUT /projects "{\"title\":$(json_string "$title"),\"identifier\":$(json_string "$identifier"),\"hex_color\":$(json_string "$color")}" "$token"
}

create_task() {
	local token="$1"
	local project_id="$2"
	local title="$3"
	local description="$4"
	api PUT "/projects/$project_id/tasks" "{\"title\":$(json_string "$title"),\"description\":$(json_string "$description")}" "$token"
}

share_project_readonly() {
	local token="$1"
	local project_id="$2"
	local username="$3"
	api PUT "/projects/$project_id/users" "{\"username\":$(json_string "$username"),\"permission\":0}" "$token"
}

wait_for_api
mkdir -p "$RUN_DIR"

curl -fsS -X DELETE "$API_BASE/api/v1/test/all" -H "Authorization: $TESTING_TOKEN" >/dev/null

PASSWORD_A="NiroUserA!2026"
PASSWORD_B="NiroUserB!2026"
USER_A="niro-user-a"
USER_B="niro-user-b"
EMAIL_A="niro-user-a@example.test"
EMAIL_B="niro-user-b@example.test"

register_user "$USER_A" "$EMAIL_A" "$PASSWORD_A"
register_user "$USER_B" "$EMAIL_B" "$PASSWORD_B"

TOKEN_A="$(login_user "$USER_A" "$PASSWORD_A")"
TOKEN_B="$(login_user "$USER_B" "$PASSWORD_B")"

PROJECT_A="$(create_project "$TOKEN_A" "Niro User A Private Project" "NIRA" "2d6cdf")"
PROJECT_B="$(create_project "$TOKEN_B" "Niro User B Private Project" "NIRB" "f59f00")"
PROJECT_SHARED="$(create_project "$TOKEN_A" "Niro User A Readonly Share" "NIRS" "43a047")"

PROJECT_A_ID="$(jq -r '.id' <<<"$PROJECT_A")"
PROJECT_B_ID="$(jq -r '.id' <<<"$PROJECT_B")"
PROJECT_SHARED_ID="$(jq -r '.id' <<<"$PROJECT_SHARED")"

TASK_A="$(create_task "$TOKEN_A" "$PROJECT_A_ID" "User A private seed task" "Owned only by niro-user-a.")"
TASK_B="$(create_task "$TOKEN_B" "$PROJECT_B_ID" "User B private seed task" "Owned only by niro-user-b.")"
TASK_SHARED="$(create_task "$TOKEN_A" "$PROJECT_SHARED_ID" "Shared readonly seed task" "Readable by niro-user-b through project share.")"
SHARE_AB="$(share_project_readonly "$TOKEN_A" "$PROJECT_SHARED_ID" "$USER_B")"

TASK_A_ID="$(jq -r '.id' <<<"$TASK_A")"
TASK_B_ID="$(jq -r '.id' <<<"$TASK_B")"
TASK_SHARED_ID="$(jq -r '.id' <<<"$TASK_SHARED")"
SHARE_AB_ID="$(jq -r '.id' <<<"$SHARE_AB")"

cat > "$NIRO_DIR/credentials.yaml" <<EOF
credentials:
  - credential_id: STANDARD_USER_A
    description: "Local username/password login at /api/v1/login. Standard user niro-user-a owns project $PROJECT_A_ID and shared-readonly source project $PROJECT_SHARED_ID; no instance-admin flag or licensed admin-panel entitlement."
    type: username_password
    identifier: "$USER_A"
    secret: "$PASSWORD_A"

  - credential_id: STANDARD_USER_B
    description: "Local username/password login at /api/v1/login. Standard user niro-user-b owns project $PROJECT_B_ID and has read-only access to niro-user-a project $PROJECT_SHARED_ID through users_projects share $SHARE_AB_ID; no write/admin rights there."
    type: username_password
    identifier: "$USER_B"
    secret: "$PASSWORD_B"
EOF

cat > "$NIRO_DIR/fixtures.yaml" <<EOF
fixtures:
  - name: local_runtime
    description: "Niro-managed Vikunja runtime built from the current checkout."
    value:
      frontend_url: "$FRONTEND_BASE"
      api_v1_url: "$FRONTEND_BASE/api/v1"
      api_v2_url: "$FRONTEND_BASE/api/v2"

  - name: standard_user_a_private_project
    description: "Project owned only by STANDARD_USER_A for horizontal authorization checks."
    value:
      owner_credential_id: STANDARD_USER_A
      project_id: $PROJECT_A_ID
      identifier: NIRA
      task_id: $TASK_A_ID

  - name: standard_user_b_private_project
    description: "Project owned only by STANDARD_USER_B for horizontal authorization checks."
    value:
      owner_credential_id: STANDARD_USER_B
      project_id: $PROJECT_B_ID
      identifier: NIRB
      task_id: $TASK_B_ID

  - name: readonly_project_share_a_to_b
    description: "STANDARD_USER_A-owned project shared read-only to STANDARD_USER_B."
    value:
      owner_credential_id: STANDARD_USER_A
      shared_with_credential_id: STANDARD_USER_B
      project_id: $PROJECT_SHARED_ID
      task_id: $TASK_SHARED_ID
      users_projects_share_id: $SHARE_AB_ID
      permission: read
EOF

echo "Seeded deterministic Niro users and fixtures."
