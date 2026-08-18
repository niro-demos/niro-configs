#!/usr/bin/env bash
# Build the current checkout and start Keycloak in Quarkus dev mode.
#
# Serves quarkus/server against the working tree (via `mvnw compile quarkus:dev`),
# so no stale build or prebuilt image is ever used. State is persisted under
# gitignored niro/harness/run/ so restarts keep the seeded baseline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

if is_running; then
  echo "Keycloak dev server already running (pid $(cat "$PID_FILE")) at $BASE_URL"
  exit 0
fi
rm -f "$PID_FILE"

echo "Building Keycloak from the current checkout (skips tests; first run can take several minutes)..."
"$REPO_ROOT/mvnw" -f "$REPO_ROOT/pom.xml" install \
  -DskipTestsuite -DskipExamples -DskipTests -DskipProtoLock=true -q

mkdir -p "$KC_HOME_DIR"

# KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD are only honored by Keycloak on the very
# first boot (empty master realm). Set them only when no DB file exists yet so
# a later `start` after a manual stop doesn't try to recreate it.
if [[ ! -d "$KC_HOME_DIR/data" ]]; then
  export KC_BOOTSTRAP_ADMIN_USERNAME="${KC_BOOTSTRAP_ADMIN_USERNAME:-$KC_BOOTSTRAP_ADMIN_USERNAME_DEFAULT}"
  export KC_BOOTSTRAP_ADMIN_PASSWORD="${KC_BOOTSTRAP_ADMIN_PASSWORD:-$KC_BOOTSTRAP_ADMIN_PASSWORD_DEFAULT}"
fi

echo "Starting Keycloak (Quarkus dev mode) on $BASE_URL ..."
nohup "$REPO_ROOT/mvnw" -f "$REPO_ROOT/quarkus/server/pom.xml" compile quarkus:dev \
  -Dkc.config.built=true -Dquarkus.args="start-dev" \
  -Dkc.home.dir="$KC_HOME_DIR" \
  -Dquarkus.http.host=0.0.0.0 \
  > "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

echo "Waiting for Keycloak to become ready..."
if wait_for_ready 90; then
  echo "Keycloak is up at $BASE_URL"
  echo "  Admin console:   $BASE_URL/admin/master/console/"
  echo "  Account console: $BASE_URL/realms/master/account/"
else
  echo "Keycloak did not become ready in time; see $LOG_FILE" >&2
  exit 1
fi
