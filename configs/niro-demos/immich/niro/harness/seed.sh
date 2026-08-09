#!/usr/bin/env bash
# Create a deterministic Immich baseline against an already-running harness
# (run start.sh first) and generate ../credentials.yaml + ../fixtures.yaml.
#
# Idempotent: safe to re-run against a runtime that already has the baseline
# (logs in instead of re-creating, reuses existing album/shared-link/API key
# when found).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

if ! wait_for_ping 60; then
  log "immich-server is not reachable at ${BASE_URL}. Run start.sh first."
  exit 1
fi

mkdir -p "${RUN_DIR}/state" "${RUN_DIR}/fixtures"

STATE_DIR="${RUN_DIR}/state"
ADMIN_API_KEY_FILE="${STATE_DIR}/admin_api_key.secret"

# Real (but tiny), DISTINCT 1x1 PNGs so thumbnail/metadata jobs have valid
# bytes to work with, and so uploads don't collide on Immich's
# checksum-based dedup (identical bytes uploaded twice return the SAME
# asset id, which would make asset_a1/asset_a2 indistinguishable).
make_sample_image() {
  local path="$1" r="$2" g="$3" b="$4"
  if [[ -f "${path}" ]]; then
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "${path}" "${r}" "${g}" "${b}" <<'PY'
import struct, sys, zlib

path, r, g, b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])

def chunk(tag, data):
    return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag + data) & 0xFFFFFFFF)

sig = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('!IIBBBBB', 1, 1, 8, 2, 0, 0, 0)  # 1x1, 8-bit, RGB
raw = bytes([0, r, g, b])  # filter-type byte + one RGB pixel
idat = zlib.compress(raw)
png = sig + chunk(b'IHDR', ihdr) + chunk(b'IDAT', idat) + chunk(b'IEND', b'')
with open(path, 'wb') as f:
    f.write(png)
PY
  else
    log "python3 not found; falling back to a base PNG with distinct trailing bytes."
    base64 -d >"${path}" <<'B64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=
B64
    printf 'niro-%s-%s-%s-%s' "${r}" "${g}" "${b}" "$(date +%s%N)" >>"${path}"
  fi
}

SAMPLE_A1="${RUN_DIR}/fixtures/sample-a1.png"
SAMPLE_A2="${RUN_DIR}/fixtures/sample-a2.png"
SAMPLE_B1="${RUN_DIR}/fixtures/sample-b1.png"
make_sample_image "${SAMPLE_A1}" 220 20 60
make_sample_image "${SAMPLE_A2}" 20 140 220
make_sample_image "${SAMPLE_B1}" 40 200 80

# ---------------------------------------------------------------------------
# Admin bootstrap
# ---------------------------------------------------------------------------
log "Bootstrapping admin account (${ADMIN_EMAIL})..."
ADMIN_TOKEN="$(login "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")"
if [[ -z "${ADMIN_TOKEN}" || "${ADMIN_TOKEN}" == "null" ]]; then
  api_call POST /auth/admin-sign-up "$(jq -nc --arg e "${ADMIN_EMAIL}" --arg p "${ADMIN_PASSWORD}" --arg n "${ADMIN_NAME}" '{email:$e,password:$p,name:$n}')"
  if [[ "${RESP_STATUS}" != "201" ]]; then
    log "admin-sign-up failed (status ${RESP_STATUS}): ${RESP_BODY}"
    exit 1
  fi
  ADMIN_TOKEN="$(login "${ADMIN_EMAIL}" "${ADMIN_PASSWORD}")"
fi
if [[ -z "${ADMIN_TOKEN}" || "${ADMIN_TOKEN}" == "null" ]]; then
  log "Could not obtain an admin access token."
  exit 1
fi

api_call POST /system-metadata/admin-onboarding '{"isOnboarded":true}' "${ADMIN_TOKEN}"
if [[ "${RESP_STATUS}" != "204" && "${RESP_STATUS}" != "200" ]]; then
  log "Warning: admin onboarding update returned status ${RESP_STATUS}: ${RESP_BODY}"
fi

ADMIN_ID="$(api_call GET /users/me '' "${ADMIN_TOKEN}"; echo "${RESP_BODY}" | jq -r '.id')"

# ---------------------------------------------------------------------------
# Standard users (2 users owning DIFFERENT resources, for horizontal-
# escalation testing; both are non-admin, for vertical-escalation testing).
# ---------------------------------------------------------------------------
create_or_login_user() {
  local email="$1" password="$2" name="$3"
  local token
  token="$(login "${email}" "${password}")"
  if [[ -z "${token}" || "${token}" == "null" ]]; then
    log "Creating standard user ${email}..."
    api_call POST /admin/users "$(jq -nc --arg e "${email}" --arg p "${password}" --arg n "${name}" '{email:$e,password:$p,name:$n,isAdmin:false}')" "${ADMIN_TOKEN}"
    if [[ "${RESP_STATUS}" != "201" ]]; then
      log "Failed to create user ${email} (status ${RESP_STATUS}): ${RESP_BODY}"
      exit 1
    fi
    token="$(login "${email}" "${password}")"
  fi
  echo "${token}"
}

USER_A_TOKEN="$(create_or_login_user "${USER_A_EMAIL}" "${USER_A_PASSWORD}" "${USER_A_NAME}")"
USER_B_TOKEN="$(create_or_login_user "${USER_B_EMAIL}" "${USER_B_PASSWORD}" "${USER_B_NAME}")"
USER_A_ID="$(api_call GET /users/me '' "${USER_A_TOKEN}"; echo "${RESP_BODY}" | jq -r '.id')"
USER_B_ID="$(api_call GET /users/me '' "${USER_B_TOKEN}"; echo "${RESP_BODY}" | jq -r '.id')"

# ---------------------------------------------------------------------------
# Sample assets: User A owns 2, User B owns 1 — distinct ownership so
# cross-user access attempts (User A reading User B's asset) have something
# real to fail at.
# ---------------------------------------------------------------------------
upload_asset() {
  local token="$1" image_path="$2" filename="$3"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
  curl -fsS -m 30 -X POST "${API}/assets" \
    -H "Authorization: Bearer ${token}" \
    -F "assetData=@${image_path};filename=${filename};type=image/png" \
    -F "fileCreatedAt=${now}" \
    -F "fileModifiedAt=${now}" \
    | jq -r '.id'
}

log "Uploading sample assets..."
ASSET_A1_ID="$(upload_asset "${USER_A_TOKEN}" "${SAMPLE_A1}" "niro-sample-a1.png")"
ASSET_A2_ID="$(upload_asset "${USER_A_TOKEN}" "${SAMPLE_A2}" "niro-sample-a2.png")"
ASSET_B1_ID="$(upload_asset "${USER_B_TOKEN}" "${SAMPLE_B1}" "niro-sample-b1.png")"

# ---------------------------------------------------------------------------
# Album owned by User A, containing User A's assets.
# ---------------------------------------------------------------------------
ALBUM_NAME="Niro Sample Album"
api_call GET /albums '' "${USER_A_TOKEN}"
ALBUM_ID="$(echo "${RESP_BODY}" | jq -r --arg n "${ALBUM_NAME}" '[.[] | select(.albumName==$n)] | .[0].id // empty')"
if [[ -z "${ALBUM_ID}" ]]; then
  log "Creating album '${ALBUM_NAME}'..."
  api_call POST /albums "$(jq -nc --arg n "${ALBUM_NAME}" --arg d "Seeded by the Niro harness for coverage of album/sharing surfaces." '{albumName:$n,description:$d}')" "${USER_A_TOKEN}"
  if [[ "${RESP_STATUS}" != "201" ]]; then
    log "Failed to create album (status ${RESP_STATUS}): ${RESP_BODY}"
    exit 1
  fi
  ALBUM_ID="$(echo "${RESP_BODY}" | jq -r '.id')"
  api_call PUT "/albums/${ALBUM_ID}/assets" "$(jq -nc --argjson ids "$(jq -nc --arg a "${ASSET_A1_ID}" --arg b "${ASSET_A2_ID}" '[$a,$b]')" '{ids:$ids}')" "${USER_A_TOKEN}"
fi

# ---------------------------------------------------------------------------
# Shared link (anonymous, link-scoped access) for the album above.
# ---------------------------------------------------------------------------
api_call GET /shared-links '' "${USER_A_TOKEN}"
SHARED_LINK_JSON="$(echo "${RESP_BODY}" | jq -c --arg id "${ALBUM_ID}" '[.[] | select(.album.id==$id)] | .[0] // empty')"
if [[ -z "${SHARED_LINK_JSON}" || "${SHARED_LINK_JSON}" == "null" ]]; then
  log "Creating shared link for '${ALBUM_NAME}'..."
  api_call POST /shared-links "$(jq -nc --arg id "${ALBUM_ID}" '{type:"ALBUM",albumId:$id,description:"Niro harness sample link",allowDownload:true,showMetadata:true}')" "${USER_A_TOKEN}"
  if [[ "${RESP_STATUS}" != "201" ]]; then
    log "Failed to create shared link (status ${RESP_STATUS}): ${RESP_BODY}"
    exit 1
  fi
  SHARED_LINK_JSON="${RESP_BODY}"
fi
SHARED_LINK_KEY="$(echo "${SHARED_LINK_JSON}" | jq -r '.key')"
SHARED_LINK_ID="$(echo "${SHARED_LINK_JSON}" | jq -r '.id')"

# ---------------------------------------------------------------------------
# Admin API key (x-api-key auth surface, distinct from bearer/session auth).
# Secrets are only shown once, so cache it and validate on re-run.
# ---------------------------------------------------------------------------
admin_api_key_valid() {
  local secret="$1"
  [[ -n "${secret}" ]] || return 1
  local status
  status="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "${API}/users/me" -H "x-api-key: ${secret}")"
  [[ "${status}" == "200" ]]
}

ADMIN_API_KEY_SECRET=""
if [[ -f "${ADMIN_API_KEY_FILE}" ]]; then
  ADMIN_API_KEY_SECRET="$(cat "${ADMIN_API_KEY_FILE}")"
fi
if ! admin_api_key_valid "${ADMIN_API_KEY_SECRET}"; then
  log "Creating admin API key..."
  api_call POST /api-keys '{"name":"niro-harness","permissions":["all"]}' "${ADMIN_TOKEN}"
  if [[ "${RESP_STATUS}" != "201" ]]; then
    log "Failed to create API key (status ${RESP_STATUS}): ${RESP_BODY}"
    exit 1
  fi
  ADMIN_API_KEY_SECRET="$(echo "${RESP_BODY}" | jq -r '.secret')"
  umask 077
  printf '%s' "${ADMIN_API_KEY_SECRET}" >"${ADMIN_API_KEY_FILE}"
fi

# ---------------------------------------------------------------------------
# Emit credentials.yaml + fixtures.yaml
# ---------------------------------------------------------------------------
CREDENTIALS_FILE="${NIRO_DIR}/credentials.yaml"
FIXTURES_FILE="${NIRO_DIR}/fixtures.yaml"

log "Writing ${CREDENTIALS_FILE}..."
cat >"${CREDENTIALS_FILE}" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/credentials.json
# GENERATED by niro/harness/seed.sh. Do not edit by hand; re-run seed.sh instead.
credentials:
  - credential_id: NIRO_ADMIN
    description: "Global/instance admin (isAdmin=true), the only account in
      this deployment. Login: POST /api/auth/login with body {email,
      password}. After login, complete onboarding with POST
      /api/system-metadata/admin-onboarding. Reaches every /api/admin/*
      surface (user management, server config, jobs, database backups) plus
      all normal user surfaces on its own assets/albums. Pair with User A
      and User B below to verify they are rejected on /api/admin/* and on
      each other's admin-only actions."
    type: username_password
    identifier: "${ADMIN_EMAIL}"
    secret: "${ADMIN_PASSWORD}"

  - credential_id: NIRO_USER_A
    description: "Standard, non-admin user. Owns 2 uploaded assets, one
      album ('${ALBUM_NAME}', id ${ALBUM_ID}), and one active shared link
      for that album. Login: POST /api/auth/login with body {email,
      password}. Pair with User B for horizontal-escalation tests
      (authenticate as A, attempt to read/modify B's asset ${ASSET_B1_ID},
      expect 403/404). Pair with the admin credential for vertical-
      escalation tests against /api/admin/*."
    type: username_password
    identifier: "${USER_A_EMAIL}"
    secret: "${USER_A_PASSWORD}"

  - credential_id: NIRO_USER_B
    description: "Standard, non-admin user. Owns 1 uploaded asset
      (${ASSET_B1_ID}), no albums. Different resources from User A on
      purpose. Login: POST /api/auth/login with body {email, password}.
      Use as the target of User A's horizontal-escalation attempts, and to
      verify User B cannot reach User A's album/shared-link."
    type: username_password
    identifier: "${USER_B_EMAIL}"
    secret: "${USER_B_PASSWORD}"

  - credential_id: NIRO_ADMIN_API_KEY
    description: "Service/API-key auth surface for the SAME admin account
      as NIRO_ADMIN (permissions=[\"all\"] — effectively full admin
      capability, NOT a reduced-scope key). Send as the 'x-api-key' request
      header (header:x-api-key). Use to probe whether the api-key auth code
      path enforces the same authorization checks as the bearer/session
      path for admin-only routes."
    type: static_token
    secret: "${ADMIN_API_KEY_SECRET}"

  - credential_id: NIRO_SHARED_LINK
    description: "Anonymous, link-scoped viewer for User A's album
      ('${ALBUM_NAME}', id ${ALBUM_ID}). Not a real user account — no
      identifier, just the link key. Send as EITHER the
      'x-immich-share-key' request header OR the 'key' query parameter
      (header:x-immich-share-key). allowDownload=true, showMetadata=true,
      no password set. Scope should be limited to this album's 2 assets
      (${ASSET_A1_ID}, ${ASSET_A2_ID}) only — use to verify a shared-link
      key cannot be used to reach User A's or User B's other
      assets/albums, or any /api/admin/* or /api/users/* surface."
    type: static_token
    secret: "${SHARED_LINK_KEY}"
EOF

log "Writing ${FIXTURES_FILE}..."
cat >"${FIXTURES_FILE}" <<EOF
# yaml-language-server: \$schema=https://niro.apxlabs.ai/schema/v1/fixtures.json
# GENERATED by niro/harness/seed.sh. Do not edit by hand; re-run seed.sh instead.
fixtures:
  - name: base_url
    description: "Base URL Niro should target. The API is mounted under /api; the web app is served at the root."
    value: "${BASE_URL}"

  - name: admin_user
    description: "Seeded admin user (NIRO_ADMIN credential). id + email for cross-referencing responses."
    value:
      id: "${ADMIN_ID}"
      email: "${ADMIN_EMAIL}"

  - name: user_a
    description: "Seeded standard user (NIRO_USER_A credential). Owns asset_a1, asset_a2, and album_a."
    value:
      id: "${USER_A_ID}"
      email: "${USER_A_EMAIL}"

  - name: user_b
    description: "Seeded standard user (NIRO_USER_B credential). Owns asset_b1 only; owns no albums."
    value:
      id: "${USER_B_ID}"
      email: "${USER_B_EMAIL}"

  - name: asset_a1
    description: "Image asset owned by User A. In album_a."
    value: "${ASSET_A1_ID}"

  - name: asset_a2
    description: "Image asset owned by User A. In album_a."
    value: "${ASSET_A2_ID}"

  - name: asset_b1
    description: "Image asset owned by User B. Not in any album. Use as the target of cross-user access attempts from User A."
    value: "${ASSET_B1_ID}"

  - name: album_a
    description: "Album '${ALBUM_NAME}' owned by User A, containing asset_a1 and asset_a2."
    value:
      id: "${ALBUM_ID}"
      name: "${ALBUM_NAME}"
      owner_user_id: "${USER_A_ID}"

  - name: shared_link_a
    description: "Active, unauthenticated shared link for album_a (also announced as the NIRO_SHARED_LINK credential secret). allowDownload=true, showMetadata=true, no password. Viewable at \${base_url}/share/${SHARED_LINK_KEY}."
    value:
      id: "${SHARED_LINK_ID}"
      key: "${SHARED_LINK_KEY}"
      album_id: "${ALBUM_ID}"
      url: "${BASE_URL}/share/${SHARED_LINK_KEY}"
EOF

log "Seed complete."
log "  Admin:   ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}"
log "  User A:  ${USER_A_EMAIL} / ${USER_A_PASSWORD} (album ${ALBUM_ID}, assets ${ASSET_A1_ID}, ${ASSET_A2_ID})"
log "  User B:  ${USER_B_EMAIL} / ${USER_B_PASSWORD} (asset ${ASSET_B1_ID})"
log "  Shared link: ${BASE_URL}/share/${SHARED_LINK_KEY}"
