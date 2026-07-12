#!/usr/bin/env bash
#
# Niro harness: start
#
# Builds crAPI from the current checkout (services/*) and brings up the full
# docker-compose service graph defined in deploy/docker/docker-compose.yml,
# then blocks until every service with a healthcheck reports healthy and the
# public gateway actually answers.
#
# Env overrides:
#   SKIP_BUILD=1   Skip `build-all.sh` and just (re)start containers from
#                  whatever images already exist locally. Use for a fast
#                  restart when you know the checkout hasn't changed.
#   VERSION        Image tag to build/run (default: latest, matches deploy/docker/.env).
#   START_TIMEOUT_SECONDS  Max seconds to wait for health (default 900).
#   ENABLE_SHELL_INJECTION / ENABLE_LOG4J
#                  crAPI ships two intentionally-vulnerable code paths gated
#                  behind these env flags, both default "false" in
#                  deploy/docker/.env:
#                    - ENABLE_SHELL_INJECTION: crapi-identity's profile-video
#                      "conversion_params" is passed unsanitized to
#                      Runtime.exec (services/identity/.../ProfileServiceImpl.java,
#                      BashCommand.java) when true.
#                    - ENABLE_LOG4J: crapi-identity logs the raw login email
#                      through log4j-core 2.14.0 (a genuinely Log4Shell-
#                      vulnerable version pinned in build.gradle.kts) when
#                      true and the email contains "jndi:"
#                      (services/identity/.../UserServiceImpl.java).
#                  This harness enables both by default (config-only, via
#                  shell env exported to `docker compose`, not by editing the
#                  committed deploy/docker/.env) so the pentest gets full
#                  coverage of these surfaces. Set either to "false" here to
#                  turn a given flag back off.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIRO_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$NIRO_DIR/.." && pwd)"
DOCKER_DIR="$REPO_ROOT/deploy/docker"
RUN_DIR="$HARNESS_DIR/run"
mkdir -p "$RUN_DIR"

export VERSION="${VERSION:-latest}"
export ENABLE_SHELL_INJECTION="${ENABLE_SHELL_INJECTION:-true}"
export ENABLE_LOG4J="${ENABLE_LOG4J:-true}"
# Bind published ports to all interfaces, not just 127.0.0.1: Niro's attack
# sandbox runs in its own Docker container and reaches the host over the
# Docker bridge gateway IP, which a loopback-only bind blocks on native Linux
# Docker (unlike Docker Desktop, which proxies host loopback automatically).
export LISTEN_IP="${LISTEN_IP:-0.0.0.0}"

cd "$DOCKER_DIR"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "[start] Building crAPI images from the current checkout (services/*)..."
  if bash ./build-all.sh > "$RUN_DIR/build-all.log" 2>&1; then
    echo "[start] Build complete. Log: $RUN_DIR/build-all.log"
  else
    echo "[start] ERROR: build-all.sh failed. Tail of $RUN_DIR/build-all.log:" >&2
    tail -80 "$RUN_DIR/build-all.log" >&2 || true
    exit 1
  fi
else
  echo "[start] SKIP_BUILD=1 set; reusing existing local images."
fi

echo "[start] Bringing up the docker compose stack..."
docker compose -f docker-compose.yml --compatibility up -d

# Services that declare a healthcheck in docker-compose.yml. crapi-chatbot has
# no healthcheck of its own (it is not on crapi-web's dependency chain), so it
# is intentionally excluded here and verified separately below.
HEALTHCHECKED_SERVICES="postgresdb mongodb chromadb mailhog crapi-identity crapi-community crapi-workshop crapi-web api.mypremiumdealership.com"

DEADLINE=$((SECONDS + ${START_TIMEOUT_SECONDS:-900}))
for svc in $HEALTHCHECKED_SERVICES; do
  echo "[start] Waiting for $svc to become healthy..."
  while true; do
    status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$svc" 2>/dev/null || echo missing)"
    if [ "$status" = "healthy" ] || [ "$status" = "no-healthcheck" ]; then
      echo "[start]   $svc: $status"
      break
    fi
    if [ "$status" = "unhealthy" ] || [ $SECONDS -ge $DEADLINE ]; then
      echo "[start] ERROR: $svc did not become healthy (status: $status). Recent logs:" >&2
      docker compose -f docker-compose.yml logs --tail=150 "$svc" >&2 || true
      exit 1
    fi
    sleep 5
  done
done

echo "[start] Waiting for crapi-chatbot container to be running (no built-in healthcheck)..."
while true; do
  status="$(docker inspect --format='{{.State.Status}}' crapi-chatbot 2>/dev/null || echo missing)"
  if [ "$status" = "running" ]; then
    echo "[start]   crapi-chatbot: running"
    break
  fi
  if [ $SECONDS -ge $DEADLINE ]; then
    echo "[start] WARN: crapi-chatbot never reached running state (status: $status)." >&2
    docker compose -f docker-compose.yml logs --tail=150 crapi-chatbot >&2 || true
    break
  fi
  sleep 5
done

BASE_URL="http://localhost:${LISTEN_PORT:-8888}"
echo "[start] Verifying gateway is reachable at $BASE_URL/health ..."
ok=0
for i in $(seq 1 60); do
  if curl -fsS "$BASE_URL/health" >/dev/null 2>&1; then
    ok=1
    break
  fi
  sleep 2
done
if [ "$ok" != "1" ]; then
  echo "[start] ERROR: $BASE_URL/health did not respond within the timeout." >&2
  exit 1
fi

echo "[start] crAPI is up and healthy at $BASE_URL"
docker compose -f docker-compose.yml ps
