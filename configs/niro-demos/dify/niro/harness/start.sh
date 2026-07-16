#!/usr/bin/env bash
# Build the current checkout and start the full Niro-managed Dify runtime.
#
# api/worker/worker_beat and web are built from this repo's own Dockerfiles
# (never a published image); db/pgvector/redis are unmodified third-party
# infrastructure images. See compose.yaml's header comment for what is
# deliberately NOT stood up here (plugin daemon, agent backend, sandbox)
# and niro/accepted-coverage-gaps.yaml for why.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

ensure_env_file

echo "harness: building api and web images from the current checkout (this can take a while on a cold cache)..."
compose build api web

echo "harness: starting the service graph..."
compose up -d

echo "harness: waiting for the api to report healthy..."
wait_for_http "http://localhost:${API_PORT}/health" 600

echo "harness: waiting for the web app to answer..."
wait_for_http "http://localhost:${WEB_PORT}/" 300

cat <<EOF
harness: up.
  Web:  http://localhost:${WEB_PORT}
  API:  http://localhost:${API_PORT}

Run ./seed.sh to (re)provision test accounts and fixtures.
EOF
