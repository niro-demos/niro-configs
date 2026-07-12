#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
RUN_DIR="$HARNESS_DIR/run"
PID_FILE="$RUN_DIR/app.pid"
LOG_FILE="$RUN_DIR/app.log"
TARGET_URL="http://127.0.0.1:9090/VulnerableApp"

mkdir -p "$RUN_DIR"
if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  curl --fail --silent --show-error "$TARGET_URL/scanner" >/dev/null
  exit 0
fi

rm -f "$PID_FILE" "$LOG_FILE"
cd "$ROOT_DIR"
./gradlew bootJar --no-daemon >"$LOG_FILE" 2>&1
APP_JAR="$(find "$ROOT_DIR/build/libs" -maxdepth 1 -type f -name 'VulnerableApp-*.jar' ! -name '*-plain.jar' | head -1)"
if [[ -z "$APP_JAR" ]]; then
  echo "bootJar did not produce an application jar" >&2
  exit 1
fi
setsid sh -c 'echo $$ >"$1"; exec env DB_ADMIN_USERNAME=admin DB_ADMIN_PASSWORD=hacker DB_APP_PASSWORD=hacker SPRING_MAIL_HOST=127.0.0.1 java -jar "$2" >>"$3" 2>&1' sh "$PID_FILE" "$APP_JAR" "$LOG_FILE" </dev/null >/dev/null 2>&1 &

for _ in $(seq 1 120); do
  if curl --fail --silent "$TARGET_URL/scanner" >/dev/null 2>&1; then
    exit 0
  fi
  if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    tail -100 "$LOG_FILE" >&2
    exit 1
  fi
  sleep 1
done

tail -100 "$LOG_FILE" >&2
exit 1
