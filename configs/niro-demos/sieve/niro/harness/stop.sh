#!/usr/bin/env bash
set -euo pipefail

if docker container inspect sieve-niro >/dev/null 2>&1; then
  docker rm -f sieve-niro >/dev/null
fi
