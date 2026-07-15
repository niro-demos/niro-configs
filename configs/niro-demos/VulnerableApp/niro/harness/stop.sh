#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_FILE="$ROOT/niro/harness/run/container.id"

if [[ ! -f "$CONTAINER_FILE" ]]; then
  exit 0
fi

docker rm -f "$(<"$CONTAINER_FILE")" >/dev/null 2>&1 || true
rm -f "$CONTAINER_FILE"
