#!/usr/bin/env bash
set -euo pipefail
docker rm -f niro-webgoat >/dev/null 2>&1 || true
