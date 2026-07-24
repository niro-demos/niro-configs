#!/usr/bin/env bash
# Seed a deterministic baseline into a running harness and (re)generate
# ../credentials.yaml and ../fixtures.yaml. Idempotent: safe to re-run
# against an already-seeded stack (passwords are reset to the same
# persisted values every time; app/dataset/api-key creation is skipped
# once fixtures.json already has them).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=lib.sh
source ./lib.sh

ensure_secrets

BASE_URL="$(read_base_url)"
if [ -z "${BASE_URL}" ]; then
  BASE_URL="http://localhost:${NIRO_NGINX_PORT}"
fi

echo "Seeding against ${BASE_URL}"

echo "Waiting for ${BASE_URL} to answer..."
deadline=$(( $(date +%s) + 180 ))
until curl -fsS "${BASE_URL}/console/api/setup" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "${deadline}" ]; then
    echo "ERROR: ${BASE_URL} is not answering. Run start.sh first." >&2
    exit 1
  fi
  sleep 3
done

COOKIE_DIR="${NIRO_RUN_DIR}/cookies"
mkdir -p "${COOKIE_DIR}"
STATE_DIR="${NIRO_RUN_DIR}/state"
mkdir -p "${STATE_DIR}"

get_cookie() {
  # $1=jar file, $2=cookie name
  awk -F'\t' -v n="$2" '$6==n{v=$7} END{print v}' "$1" 2>/dev/null
}

json_get() {
  # $1=field path (python expression on parsed json), reads json from stdin
  python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(\"d$1\"))"
}

# --- 1. First-time system bootstrap (idempotent: only runs once ever) ---
setup_step="$(curl -sS "${BASE_URL}/console/api/setup" | json_get "['step']")"
echo "Setup status: ${setup_step}"

if [ "${setup_step}" = "not_started" ]; then
  echo "Running first-time bootstrap (init password + owner account)..."
  init_jar="${COOKIE_DIR}/bootstrap.jar"
  rm -f "${init_jar}"
  curl -sS -c "${init_jar}" -b "${init_jar}" -X POST "${BASE_URL}/console/api/init" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "import json; print(json.dumps({'password': __import__('os').environ['NIRO_INIT_PASSWORD']}))")"
  echo
  curl -sS -c "${init_jar}" -b "${init_jar}" -X POST "${BASE_URL}/console/api/setup" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import json, os
print(json.dumps({
    'email': os.environ['NIRO_OWNER_A_EMAIL'],
    'name': 'Owner A',
    'password': os.environ['NIRO_OWNER_A_PASSWORD'],
    'language': 'en-US',
}))
")"
  echo
fi

# --- 2. Accounts, tenants, roles (idempotent; runs the seed_accounts.py
#         helper inside the api container so it has DB + app context) ---
# Copied to /app/api/ (not /tmp/) so its own directory matches the app's
# cwd/sys.path[0] and `from app_factory import ...` resolves.
echo "Seeding accounts/tenants..."
compose cp "${NIRO_HARNESS_DIR}/seed/seed_accounts.py" api:/app/api/niro_seed_accounts.py

ACCOUNTS_JSON="$(python3 - <<'PYEOF'
import json
import os

accounts = [
    {
        "email": os.environ["NIRO_OWNER_A_EMAIL"],
        "name": "Owner A",
        "password": os.environ["NIRO_OWNER_A_PASSWORD"],
        "role": "owner",
        "tenant_name": "Org A",
        "join_tenant_of": None,
    },
    {
        "email": os.environ["NIRO_NORMAL_A_EMAIL"],
        "name": "Member A",
        "password": os.environ["NIRO_NORMAL_A_PASSWORD"],
        "role": "normal",
        "join_tenant_of": os.environ["NIRO_OWNER_A_EMAIL"],
    },
    {
        "email": os.environ["NIRO_OWNER_B_EMAIL"],
        "name": "Owner B",
        "password": os.environ["NIRO_OWNER_B_PASSWORD"],
        "role": "owner",
        "tenant_name": "Org B",
        "join_tenant_of": None,
    },
    {
        "email": os.environ["NIRO_NORMAL_B_EMAIL"],
        "name": "Member B",
        "password": os.environ["NIRO_NORMAL_B_PASSWORD"],
        "role": "normal",
        "join_tenant_of": os.environ["NIRO_OWNER_B_EMAIL"],
    },
]
print(json.dumps(accounts))
PYEOF
)"

ACCOUNTS_SPEC_FILE="${STATE_DIR}/accounts-spec.json"
echo "${ACCOUNTS_JSON}" > "${ACCOUNTS_SPEC_FILE}"
compose cp "${ACCOUNTS_SPEC_FILE}" api:/tmp/niro-accounts-spec.json
compose exec -T -e NIRO_SPEC_PATH=/tmp/niro-accounts-spec.json api python /app/api/niro_seed_accounts.py

# --- 3. Apps, datasets, and service API keys, owned per-tenant ---------
login() {
  # $1=email $2=password $3=jar
  # The console login endpoint expects the password field base64-encoded
  # (controllers/console/wraps.py:decrypt_password_field / FieldEncryption
  # -- it's an obfuscation layer over HTTP, not real crypto, but a plain
  # non-base64 password string fails to decode and the login is rejected).
  rm -f "$3"
  local resp
  resp="$(curl -sS -c "$3" -b "$3" -X POST "${BASE_URL}/console/api/login" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c "
import base64, json, sys
email, password = sys.argv[1], sys.argv[2]
encoded_password = base64.b64encode(password.encode()).decode()
print(json.dumps({'email': email, 'password': encoded_password, 'remember_me': False}))
" "$1" "$2")")"
  if ! echo "${resp}" | grep -q '"result":[[:space:]]*"success"'; then
    echo "ERROR: login failed for $1: ${resp}" >&2
    return 1
  fi
}

authed_post() {
  # $1=jar $2=path $3=json body (or "" for none)
  local csrf
  csrf="$(get_cookie "$1" csrf_token)"
  curl -sS -c "$1" -b "$1" -X POST "${BASE_URL}$2" \
    -H 'Content-Type: application/json' \
    -H "X-CSRF-Token: ${csrf}" \
    -d "${3:-{\}}"
}

authed_get() {
  # $1=jar $2=path
  # This deployment enforces the CSRF header check on every non-OPTIONS
  # request behind @login_required, GET included (libs/login.py), not just
  # state-changing methods.
  local csrf
  csrf="$(get_cookie "$1" csrf_token)"
  curl -sS -c "$1" -b "$1" -X GET "${BASE_URL}$2" -H "X-CSRF-Token: ${csrf}"
}

find_or_create_app() {
  # $1=jar $2=app name -> prints app id
  local jar="$1" name="$2" list_resp existing
  list_resp="$(authed_get "${jar}" "/console/api/apps?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${name}")")"
  existing="$(echo "${list_resp}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for item in d.get('data', []):
    if item.get('name') == sys.argv[1]:
        print(item['id'])
        break
" "${name}")"
  if [ -n "${existing}" ]; then
    echo "${existing}"
    return 0
  fi
  authed_post "${jar}" "/console/api/apps" "$(python3 -c "import json,sys; print(json.dumps({'name': sys.argv[1], 'mode': 'chat'}))" "${name}")" | json_get "['id']"
}

find_or_create_dataset() {
  # $1=jar $2=dataset name -> prints dataset id
  local jar="$1" name="$2" list_resp existing
  list_resp="$(authed_get "${jar}" "/console/api/datasets?keyword=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${name}")")"
  existing="$(echo "${list_resp}" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for item in d.get('data', []):
    if item.get('name') == sys.argv[1]:
        print(item['id'])
        break
" "${name}")"
  if [ -n "${existing}" ]; then
    echo "${existing}"
    return 0
  fi
  authed_post "${jar}" "/console/api/datasets" "$(python3 -c "import json,sys; print(json.dumps({'name': sys.argv[1]}))" "${name}")" | json_get "['id']"
}

seed_org_fixtures() {
  # $1=org label (A/B) $2=email $3=password
  local label="$1" email="$2" password="$3"
  local jar="${COOKIE_DIR}/${label}.jar"
  login "${email}" "${password}" "${jar}"

  # Tenant A's name can't be set at creation time (POST /console/api/setup
  # takes no workspace-name field, unlike the seed_accounts.py path used for
  # Tenant B), so rename it here for a consistent, predictable "Org <label>"
  # name on both tenants. Idempotent: harmless if already named correctly.
  authed_post "${jar}" "/console/api/workspaces/info" "$(python3 -c "import json; print(json.dumps({'name': 'Org ${label}'}))")" >/dev/null

  local app_name="Niro Sample Chatbot ${label}"
  local dataset_name="Niro Sample KB ${label}"

  local app_id app_key_resp app_token
  app_id="$(find_or_create_app "${jar}" "${app_name}")"
  app_key_resp="$(authed_post "${jar}" "/console/api/apps/${app_id}/api-keys" "")"
  app_token="$(echo "${app_key_resp}" | json_get "['token']" 2>/dev/null || true)"

  local dataset_id dataset_key_resp dataset_token="null"
  dataset_id="$(find_or_create_dataset "${jar}" "${dataset_name}")"
  # NOTE: as of this checkout, POST /console/api/datasets/<id>/api-keys
  # 500s -- controllers/console/apikey.py's _create_api_key() does
  # getattr(ApiToken, self.resource_id_field) with resource_id_field
  # "dataset_id", but models.model.ApiToken has no dataset_id column
  # (only app_id). Recorded in accepted-coverage-gaps.yaml; tolerate the
  # failure here instead of aborting the whole seed run.
  dataset_key_resp="$(authed_post "${jar}" "/console/api/datasets/${dataset_id}/api-keys" "" || true)"
  if echo "${dataset_key_resp}" | grep -q '"token"'; then
    dataset_token="\"$(echo "${dataset_key_resp}" | json_get "['token']")\""
  else
    echo "NOTE: dataset API key creation failed for ${dataset_name} (known bug, see accepted-coverage-gaps.yaml): ${dataset_key_resp}" >&2
  fi

  cat > "${STATE_DIR}/org_${label}.json" <<EOF
{
  "app_id": "${app_id}",
  "app_api_token": "${app_token}",
  "dataset_id": "${dataset_id}",
  "dataset_api_token": ${dataset_token}
}
EOF
  echo "Org ${label}: app=${app_id} dataset=${dataset_id}"
}

echo "Seeding sample app + dataset + API keys for Org A..."
seed_org_fixtures A "${NIRO_OWNER_A_EMAIL}" "${NIRO_OWNER_A_PASSWORD}"
echo "Seeding sample app + dataset + API keys for Org B..."
seed_org_fixtures B "${NIRO_OWNER_B_EMAIL}" "${NIRO_OWNER_B_PASSWORD}"

# --- 4. Emit credentials.yaml + fixtures.yaml ---------------------------
python3 "${NIRO_HARNESS_DIR}/seed/render_manifests.py" \
  --base-url "${BASE_URL}" \
  --state-dir "${STATE_DIR}" \
  --out-credentials "${NIRO_CONFIG_DIR}/credentials.yaml" \
  --out-fixtures "${NIRO_CONFIG_DIR}/fixtures.yaml"

echo "Wrote ${NIRO_CONFIG_DIR}/credentials.yaml and ${NIRO_CONFIG_DIR}/fixtures.yaml"
echo "Seed complete."
