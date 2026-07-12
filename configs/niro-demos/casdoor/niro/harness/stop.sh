#!/usr/bin/env bash
set -euo pipefail
docker rm -f casdoor-niro >/dev/null 2>&1 || true
docker rm -f casdoor-niro-mysql >/dev/null 2>&1 || true
