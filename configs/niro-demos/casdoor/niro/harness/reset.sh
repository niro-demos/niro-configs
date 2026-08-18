#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/run"

"${SCRIPT_DIR}/stop.sh"
rm -f "${RUN_DIR}/seed.cookies" "${RUN_DIR}/webhook/events.jsonl"
mkdir -p "${RUN_DIR}/mysql" "${RUN_DIR}/storage" "${RUN_DIR}/webhook"
docker run --rm -v "${RUN_DIR}/mysql:/mysql" mysql:8.0.25 bash -c 'shopt -s dotglob nullglob && rm -rf /mysql/*'
docker run --rm -v "${RUN_DIR}/storage:/storage" alpine:latest sh -c 'find /storage -mindepth 1 -delete'
docker run --rm -v "${RUN_DIR}/storage:/storage" alpine:latest chown -R 1000:1000 /storage
"${SCRIPT_DIR}/start.sh"
"${SCRIPT_DIR}/seed.sh"
