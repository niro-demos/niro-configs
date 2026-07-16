#!/usr/bin/env bash
# Shared environment for the n8n Niro harness. Sourced by start/stop/seed/reset.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$HARNESS_DIR/../.." && pwd)"
RUN_DIR="$HARNESS_DIR/run"
DATA_DIR="$RUN_DIR/data"
LOG_FILE="$RUN_DIR/n8n.log"
PID_FILE="$RUN_DIR/n8n.pid"

N8N_PORT_VALUE="5678"
N8N_BASE_URL="http://localhost:${N8N_PORT_VALUE}"

mkdir -p "$RUN_DIR" "$DATA_DIR"

# Deterministic, local-only settings so start/reset always produce the same
# reachable target. Not secrets: this instance only ever runs on localhost
# inside the CI/dev sandbox.
export N8N_USER_FOLDER="$DATA_DIR"
export N8N_PORT="$N8N_PORT_VALUE"
export N8N_PROTOCOL="http"
export N8N_LISTEN_ADDRESS="0.0.0.0"
export N8N_ENCRYPTION_KEY="niro-harness-fixed-encryption-key-v1"
export N8N_SECURE_COOKIE="false"
export N8N_DIAGNOSTICS_ENABLED="false"
export N8N_VERSION_NOTIFICATIONS_ENABLED="false"
export N8N_TEMPLATES_ENABLED="false"
export N8N_HIRING_BANNER_ENABLED="false"
export N8N_PERSONALIZATION_ENABLED="false"
export N8N_PUBLIC_API_DISABLED="false"
export N8N_RUNNERS_ENABLED="true"
export DB_TYPE="sqlite"
export N8N_LOG_LEVEL="info"
export N8N_LOG_OUTPUT="console"

healthz_url() {
	echo "${N8N_BASE_URL}/healthz"
}

# /healthz goes green as soon as the Express app is listening; routes and DB
# migrations can still be mid-registration then, so a request right after can
# 404 (Cannot POST /rest/owner/setup). /healthz/readiness only turns green
# after DB connect + migrate + full app init — use it to gate seeding.
readiness_url() {
	echo "${N8N_BASE_URL}/healthz/readiness"
}
