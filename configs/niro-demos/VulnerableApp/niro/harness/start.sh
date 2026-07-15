#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="$ROOT/niro/harness/run"
CONTAINER_FILE="$RUN/container.id"
URL="http://172.17.0.1:9090/VulnerableApp/"

mkdir -p "$RUN"
if [[ -f "$CONTAINER_FILE" ]] && docker inspect --format '{{.State.Running}}' "$(<"$CONTAINER_FILE")" 2>/dev/null | grep -qx true; then
  curl --fail --silent --show-error "$URL" >/dev/null
  exit 0
fi

cd "$ROOT"
./gradlew --no-daemon jibDockerBuild
docker rm -f niro-vulnerableapp >/dev/null 2>&1 || true
mkdir -p "$RUN/logs"
rm -f "$RUN/logs/application.log"
docker run --detach --name niro-vulnerableapp --publish 0.0.0.0:9090:9090 \
  --env LOGGING_CONFIG=file:/niro-config/log4j2.xml \
  --volume "$RUN/logs:/niro-logs" \
  --volume "$ROOT/niro/harness/log4j2.xml:/niro-config/log4j2.xml:ro" \
  sasanlabs/owasp-vulnerableapp:unreleased >"$CONTAINER_FILE"

for _ in $(seq 1 120); do
  if curl --fail --silent --show-error "$URL" >/dev/null 2>&1; then
    exit 0
  fi
  if ! docker inspect --format '{{.State.Running}}' "$(<"$CONTAINER_FILE")" 2>/dev/null | grep -qx true; then
    docker logs --tail 100 "$(<"$CONTAINER_FILE")" >&2
    exit 1
  fi
  sleep 1
done

echo "Application did not become healthy at $URL" >&2
docker logs --tail 100 "$(<"$CONTAINER_FILE")" >&2
exit 1
