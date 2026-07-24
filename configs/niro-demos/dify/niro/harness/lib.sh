#!/usr/bin/env bash
# Shared paths, env, and helpers for start.sh / stop.sh / seed.sh / reset.sh.
# Source this file; do not execute it directly.

set -euo pipefail

# --- paths -------------------------------------------------------------
# Resolve everything from this file's location so the scripts work
# regardless of the caller's working directory.
NIRO_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_CONFIG_DIR="$(cd "${NIRO_HARNESS_DIR}/.." && pwd)"
NIRO_REPO_ROOT="$(cd "${NIRO_CONFIG_DIR}/.." && pwd)"
NIRO_DOCKER_DIR="${NIRO_REPO_ROOT}/docker"
NIRO_RUN_DIR="${NIRO_HARNESS_DIR}/run"

export NIRO_HARNESS_DIR NIRO_CONFIG_DIR NIRO_REPO_ROOT NIRO_DOCKER_DIR NIRO_RUN_DIR

COMPOSE_PROJECT_NAME="niro-dify"
COMPOSE_BASE_FILE="${NIRO_DOCKER_DIR}/docker-compose.yaml"
COMPOSE_OVERRIDE_FILE="${NIRO_HARNESS_DIR}/docker-compose.override.yaml"
DOCKER_ENV_FILE="${NIRO_DOCKER_DIR}/.env"
SECRETS_FILE="${NIRO_RUN_DIR}/.harness-secrets.env"

# --- container runtime detection (docker or podman) ---------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_BIN=(docker compose)
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE_BIN=(podman-compose)
else
  echo "ERROR: docker compose (or podman-compose) is required but was not found." >&2
  exit 1
fi

compose() {
  "${COMPOSE_BIN[@]}" \
    -f "${COMPOSE_BASE_FILE}" \
    -f "${COMPOSE_OVERRIDE_FILE}" \
    --env-file "${DOCKER_ENV_FILE}" \
    -p "${COMPOSE_PROJECT_NAME}" \
    "$@"
}

# --- free-port picker ---------------------------------------------------
port_is_free() {
  local port="$1"
  ! (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
}

pick_free_port() {
  local start="$1"
  local port="$start"
  for _ in $(seq 1 50); do
    if port_is_free "$port"; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
  done
  echo "ERROR: could not find a free port starting at ${start}" >&2
  return 1
}

# --- one-time secret / port generation, persisted across restarts -------
ensure_secrets() {
  mkdir -p "${NIRO_RUN_DIR}"
  if [ ! -f "${SECRETS_FILE}" ]; then
    local init_password secret_key nginx_port
    init_password="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')"
    secret_key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(42))')"
    nginx_port="$(pick_free_port 18080)"
    # Fixed test-actor identities + passwords, generated once and reused by
    # every start/seed/reset so the DB and credentials.yaml stay in sync
    # across restarts. Passwords always satisfy libs/password.py's pattern
    # (letters + digits, 8+ chars) via the NiroSeed1- prefix.
    cat > "${SECRETS_FILE}" <<EOF
NIRO_INIT_PASSWORD=${init_password}
NIRO_SECRET_KEY=${secret_key}
NIRO_NGINX_PORT=${nginx_port}
NIRO_OWNER_A_EMAIL=owner-a@niro.test
NIRO_OWNER_A_PASSWORD=NiroSeed1-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
NIRO_NORMAL_A_EMAIL=member-a@niro.test
NIRO_NORMAL_A_PASSWORD=NiroSeed1-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
NIRO_OWNER_B_EMAIL=owner-b@niro.test
NIRO_OWNER_B_PASSWORD=NiroSeed1-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
NIRO_NORMAL_B_EMAIL=member-b@niro.test
NIRO_NORMAL_B_PASSWORD=NiroSeed1-$(python3 -c 'import secrets; print(secrets.token_urlsafe(12))')
EOF
    echo "Generated harness secrets and picked port ${nginx_port} (${SECRETS_FILE})"
  fi
  # shellcheck disable=SC1090
  source "${SECRETS_FILE}"
  export NIRO_INIT_PASSWORD NIRO_SECRET_KEY NIRO_NGINX_PORT
  export NIRO_OWNER_A_EMAIL NIRO_OWNER_A_PASSWORD
  export NIRO_NORMAL_A_EMAIL NIRO_NORMAL_A_PASSWORD
  export NIRO_OWNER_B_EMAIL NIRO_OWNER_B_PASSWORD
  export NIRO_NORMAL_B_EMAIL NIRO_NORMAL_B_PASSWORD
}

# --- docker/.env: standard `cp .env.example .env`, then patch our knobs -
ensure_docker_env() {
  if [ ! -f "${DOCKER_ENV_FILE}" ]; then
    cp "${NIRO_DOCKER_DIR}/.env.example" "${DOCKER_ENV_FILE}"
  fi
  set_env_var() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "${DOCKER_ENV_FILE}"; then
      sed -i "s|^${key}=.*|${key}=${value}|" "${DOCKER_ENV_FILE}"
    else
      printf '%s=%s\n' "${key}" "${value}" >> "${DOCKER_ENV_FILE}"
    fi
  }
  set_env_var INIT_PASSWORD "${NIRO_INIT_PASSWORD}"
  set_env_var SECRET_KEY "${NIRO_SECRET_KEY}"
  set_env_var EXPOSE_NGINX_PORT "${NIRO_NGINX_PORT}"
  # CORS wide open by default in .env.example already (WEB_API_CORS_ALLOW_ORIGINS=*,
  # CONSOLE_CORS_ALLOW_ORIGINS=*) which is what we want for a same-origin,
  # nginx-fronted local target.
}

# --- keep run/volumes/ traversable by the host user ---------------------
# Containers (postgres, redis, weaviate, ...) write their data as their own
# container-internal uid, with directory modes (e.g. postgres's 0700
# pgdata) the host build user often can't even list. That's harmless on
# its own, but docker/docker-compose.yaml's api/web build "context:" is
# this whole repo checkout (COPY paths like `api/pyproject.toml` require
# it), and niro/harness/run/ lives inside that checkout -- so buildkit's
# context walker chokes with EACCES on those directories even though
# Dockerfile.dockerignore excludes niro/. Fix perms via a throwaway
# container (which can act as root over the bind-mounted directory)
# instead of relying on dockerignore to prevent the walk.
fix_volume_permissions() {
  if [ -d "${NIRO_RUN_DIR}/volumes" ]; then
    docker run --rm -v "${NIRO_RUN_DIR}/volumes:/target" busybox \
      chmod -R a+rX /target >/dev/null
  fi
}

BASE_URL_FILE="${NIRO_RUN_DIR}/base_url.txt"

write_base_url() {
  mkdir -p "${NIRO_RUN_DIR}"
  echo "http://localhost:${NIRO_NGINX_PORT}" > "${BASE_URL_FILE}"
}

read_base_url() {
  if [ -f "${BASE_URL_FILE}" ]; then
    cat "${BASE_URL_FILE}"
  else
    echo ""
  fi
}
