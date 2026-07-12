#!/usr/bin/env bash
# start.sh — Build and start DVWA from the current checkout, then seed it.
#
# Serves the working-tree code (bind-mounted into the container), sets
# DEFAULT_SECURITY_LEVEL=low, and runs the DB bootstrap (setup.php).
# Prints the target URL on success.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.harness.yml"
RUN_DIR="$SCRIPT_DIR/run"
PORT="${DVWA_PORT:-4280}"
BASE_URL="http://127.0.0.1:${PORT}"

mkdir -p "$RUN_DIR"
export DVWA_PORT="$PORT"

# DVWA requires config/config.inc.php to exist (gitignored). Create it from the
# dist template if missing — env vars (DB_SERVER, DEFAULT_SECURITY_LEVEL, …) are
# read via getenv() in the dist file, so no manual editing is needed.
CONFIG_PHP="$PROJECT_ROOT/config/config.inc.php"
CONFIG_DIST="$PROJECT_ROOT/config/config.inc.php.dist"
if [ ! -f "$CONFIG_PHP" ] && [ -f "$CONFIG_DIST" ]; then
  cp "$CONFIG_DIST" "$CONFIG_PHP"
  echo "[start] created config/config.inc.php from dist"
fi

echo "[start] building and starting DVWA from $PROJECT_ROOT"
docker compose -f "$COMPOSE_FILE" --project-name niro-dvwa up -d --build

# Wait for the app to respond.
echo "[start] waiting for $BASE_URL to become healthy"
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "$BASE_URL/login.php" 2>/dev/null; then
    echo "[start] DVWA is up (attempt $i)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[start] ERROR: DVWA did not become healthy within 60s" >&2
    docker compose -f "$COMPOSE_FILE" --project-name niro-dvwa logs --tail=50 >&2 || true
    exit 1
  fi
  sleep 1
done

# Seed the database and generate credentials/fixtures.
echo "[start] seeding database"
"$SCRIPT_DIR/seed.sh"

echo "[start] DVWA is ready at $BASE_URL"
echo "TARGET_URL=$BASE_URL"
