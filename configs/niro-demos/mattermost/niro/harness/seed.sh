#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE=http://127.0.0.1:8065/api/v4
PASSWORD='NiroLocal-2026!Secure'

create_user() {
  local username="$1" email="$2"
  curl -fsS -o /dev/null -X POST "$BASE/users" -H 'Content-Type: application/json' \
    --data "{\"email\":\"$email\",\"username\":\"$username\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true
}
login() {
  local username="$1" headers
  headers="$(mktemp)"
  curl -fsS -D "$headers" -o /dev/null -X POST "$BASE/users/login" -H 'Content-Type: application/json' \
    --data "{\"login_id\":\"$username\",\"password\":\"$PASSWORD\"}"
  awk 'BEGIN{IGNORECASE=1} /^Token:/{gsub("\\r",""); print $2}' "$headers"
  rm -f "$headers"
}
api() { curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' "$@"; }

create_user niro-admin niro-admin@example.test
ADMIN_TOKEN="$(login niro-admin)"
ADMIN_ID="$(api "$BASE/users/username/niro-admin" | jq -r .id)"
api -X PUT "$BASE/users/$ADMIN_ID/roles" --data '{"roles":"system_user system_admin"}' >/dev/null

create_user niro-user-a niro-user-a@example.test
create_user niro-user-b niro-user-b@example.test
USER_A_ID="$(api "$BASE/users/username/niro-user-a" | jq -r .id)"
USER_B_ID="$(api "$BASE/users/username/niro-user-b" | jq -r .id)"

TEAM_ID="$(api "$BASE/teams/name/niro-team" 2>/dev/null | jq -r .id || true)"
if [[ -z "$TEAM_ID" || "$TEAM_ID" == null ]]; then
  TEAM_ID="$(api -X POST "$BASE/teams" --data '{"name":"niro-team","display_name":"Niro Pentest Team","type":"O"}' | jq -r .id)"
fi
for uid in "$ADMIN_ID" "$USER_A_ID" "$USER_B_ID"; do
  api -X POST "$BASE/teams/$TEAM_ID/members" --data "{\"team_id\":\"$TEAM_ID\",\"user_id\":\"$uid\"}" >/dev/null 2>&1 || true
done

channel_for() {
  local name="$1" display="$2" owner="$3" id
  id="$(api "$BASE/teams/$TEAM_ID/channels/name/$name" 2>/dev/null | jq -r .id || true)"
  if [[ -z "$id" || "$id" == null ]]; then
    id="$(api -X POST "$BASE/channels" --data "{\"team_id\":\"$TEAM_ID\",\"name\":\"$name\",\"display_name\":\"$display\",\"type\":\"P\"}" | jq -r .id)"
  fi
  api -X POST "$BASE/channels/$id/members" --data "{\"user_id\":\"$owner\"}" >/dev/null 2>&1 || true
  printf '%s' "$id"
}
CHANNEL_A_ID="$(channel_for niro-private-a 'Niro Private A' "$USER_A_ID")"
CHANNEL_B_ID="$(channel_for niro-private-b 'Niro Private B' "$USER_B_ID")"

cat >"$ROOT/niro/credentials.yaml" <<EOF
credentials:
  - credential_id: GLOBAL_ADMIN
    description: "Mattermost system_admin and system_user. Login POST /api/v4/users/login with {login_id,password}. Has instance-wide administration and owns the Niro team."
    type: username_password
    identifier: niro-admin
    secret: $PASSWORD
  - credential_id: STANDARD_USER_A
    description: "Mattermost system_user, member of Niro Pentest Team, owner/member of private channel niro-private-a only. Pair with STANDARD_USER_B for horizontal authorization tests. Login POST /api/v4/users/login with {login_id,password}."
    type: username_password
    identifier: niro-user-a
    secret: $PASSWORD
  - credential_id: STANDARD_USER_B
    description: "Mattermost system_user, member of Niro Pentest Team, owner/member of private channel niro-private-b only. Pair with STANDARD_USER_A for horizontal authorization tests. Login POST /api/v4/users/login with {login_id,password}."
    type: username_password
    identifier: niro-user-b
    secret: $PASSWORD
EOF
cat >"$ROOT/niro/fixtures.yaml" <<EOF
fixtures:
  - name: niro_team
    description: "Dedicated team shared by all three Niro actors."
    value: {id: "$TEAM_ID", name: "niro-team"}
  - name: standard_user_a_private_channel
    description: "Private channel belonging to User A; User B is intentionally not a member."
    value: {id: "$CHANNEL_A_ID", name: "niro-private-a", owner_user_id: "$USER_A_ID"}
  - name: standard_user_b_private_channel
    description: "Private channel belonging to User B; User A is intentionally not a member."
    value: {id: "$CHANNEL_B_ID", name: "niro-private-b", owner_user_id: "$USER_B_ID"}
EOF

# Verify every generated credential and ownership boundary.
login niro-user-a >/dev/null
login niro-user-b >/dev/null
[[ "$(api "$BASE/users/$ADMIN_ID" | jq -r .roles)" == *system_admin* ]]
[[ "$(api "$BASE/channels/$CHANNEL_A_ID/members/$USER_B_ID" -w '%{http_code}' -o /dev/null 2>/dev/null || true)" == 404 ]]

# Golden post-seed database used by reset.sh so actor and resource IDs remain stable.
docker exec niro-mattermost-postgres pg_dump -U mmuser -d mattermost --clean --if-exists >"$ROOT/niro/harness/run/golden.sql"
