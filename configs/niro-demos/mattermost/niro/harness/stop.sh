#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/niro/harness/run"
docker rm -f niro-mattermost-server >/dev/null 2>&1 || true
docker rm -f niro-mattermost-postgres >/dev/null 2>&1 || true
