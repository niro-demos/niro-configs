#!/usr/bin/env bash
set -euo pipefail

docker rm -f sieve-niro-local >/dev/null 2>&1 || true
rm -f "$(dirname "$0")/run/container-id"
