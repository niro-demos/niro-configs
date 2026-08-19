#!/usr/bin/env bash
# Shared helpers for niro/harness scripts. Sourced, not executed directly.

# Resolve absolute paths regardless of caller's cwd.
harness_lib_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NIRO_DIR/.." && pwd)"
RUN_DIR="$HARNESS_DIR/run"
KC_HOME_DIR="$RUN_DIR/kc-home"
GOLDEN_DIR="$RUN_DIR/golden-kc-home"
PID_FILE="$RUN_DIR/server.pid"
LOG_FILE="$RUN_DIR/server.log"
BASE_URL="http://localhost:8080"

mkdir -p "$RUN_DIR"

# --- Fixed, deterministic test identities for this harness -----------------
KC_BOOTSTRAP_ADMIN_USERNAME_DEFAULT="admin"
KC_BOOTSTRAP_ADMIN_PASSWORD_DEFAULT="NiroAdmin#2026"

TEST_REALM="niro-test"
TEST_APP_CLIENT_ID="niro-test-app"
TEST_SERVICE_CLIENT_ID="niro-test-service"
TEST_SERVICE_CLIENT_SECRET="NiroServiceSecret#2026"

ALICE_USERNAME="alice"
ALICE_EMAIL="alice@niro-test.local"
ALICE_PASSWORD="Alice#Test2026"

BOB_USERNAME="bob"
BOB_EMAIL="bob@niro-test.local"
BOB_PASSWORD="Bob#Test2026"

CAROL_USERNAME="carol"
CAROL_EMAIL="carol@niro-test.local"
CAROL_PASSWORD="Carol#RealmAdmin2026"

wait_for_ready() {
  local tries="${1:-90}"
  for ((i = 0; i < tries; i++)); do
    if curl -sf -o /dev/null -m 3 "$BASE_URL/realms/master"; then
      return 0
    fi
    sleep 5
  done
  return 1
}

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

admin_token() {
  local username="${KC_BOOTSTRAP_ADMIN_USERNAME:-$KC_BOOTSTRAP_ADMIN_USERNAME_DEFAULT}"
  local password="${KC_BOOTSTRAP_ADMIN_PASSWORD:-$KC_BOOTSTRAP_ADMIN_PASSWORD_DEFAULT}"
  curl -sf -X POST "$BASE_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" -d "username=$username" -d "password=$password" -d "grant_type=password" \
    | jq -r .access_token
}
