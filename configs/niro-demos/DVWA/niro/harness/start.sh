#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HARNESS_DIR/run/db"
docker compose -p niro-dvwa -f "$HARNESS_DIR/compose.yml" up -d --build --remove-orphans

for _ in $(seq 1 60); do
  if curl --fail --silent --show-error http://127.0.0.1:4280/setup.php >/dev/null; then
    "$HARNESS_DIR/seed.sh"
    exit 0
  fi
  sleep 1
done

docker compose -p niro-dvwa -f "$HARNESS_DIR/compose.yml" logs
exit 1
