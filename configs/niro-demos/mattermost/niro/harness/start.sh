#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN="$ROOT/niro/harness/run"
SERVER="$ROOT/server"
mkdir -p "$RUN/postgres" "$RUN/data" "$RUN/logs" "$RUN/plugins" "$RUN/client/plugins"

WEB_SIGNATURE="$(git -C "$ROOT" rev-parse HEAD)-$(git -C "$ROOT" diff -- webapp | sha256sum | cut -d' ' -f1)"
if [[ ! -f "$RUN/client/root.html" || ! -f "$RUN/web.signature" || "$(cat "$RUN/web.signature")" != "$WEB_SIGNATURE" ]]; then
  make -C "$ROOT/webapp" dist
  rm -rf "$RUN/client"
  mkdir -p "$RUN/client"
  cp -a "$ROOT/webapp/channels/dist/." "$RUN/client/"
  printf '%s\n' "$WEB_SIGNATURE" >"$RUN/web.signature"
fi

if curl -fsS http://127.0.0.1:8065/api/v4/system/ping >/dev/null 2>&1; then
  exit 0
fi

docker rm -f niro-mattermost-postgres >/dev/null 2>&1 || true
docker run -d --name niro-mattermost-postgres \
  -e POSTGRES_USER=mmuser -e POSTGRES_PASSWORD=mostest -e POSTGRES_DB=mattermost \
  -p 127.0.0.1:55432:5432 \
  -v "$RUN/postgres:/var/lib/postgresql/data" postgres:14-alpine >/dev/null

for _ in {1..60}; do
  if docker exec niro-mattermost-postgres pg_isready -U mmuser -d mattermost >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec niro-mattermost-postgres pg_isready -U mmuser -d mattermost >/dev/null

(cd "$SERVER" && make setup-go-work && go build -buildvcs=false -o "$RUN/mattermost" ./cmd/mattermost)

docker rm -f niro-mattermost-server >/dev/null 2>&1 || true
docker run -d --name niro-mattermost-server --network host \
  -w "$SERVER" -v "$ROOT:$ROOT" \
  -e MM_SQLSETTINGS_DRIVERNAME=postgres \
  -e 'MM_SQLSETTINGS_DATASOURCE=postgres://mmuser:mostest@127.0.0.1:55432/mattermost?sslmode=disable&connect_timeout=10' \
  -e MM_SERVICESETTINGS_SITEURL=http://127.0.0.1:8065 \
  -e MM_SERVICESETTINGS_LISTENADDRESS=0.0.0.0:8065 \
  -e MM_SERVICESETTINGS_ENABLELOCALMODE=true \
  -e MM_SERVICESETTINGS_ENABLEUSERACCESSTOKENS=true \
  -e MM_TEAMSETTINGS_ENABLEOPENSERVER=true \
  -e MM_TEAMSETTINGS_ENABLEUSERCREATION=true \
  -e MM_FILESETTINGS_DRIVERNAME=local -e MM_FILESETTINGS_DIRECTORY="$RUN/data" \
  -e MM_PLUGINSETTINGS_DIRECTORY="$RUN/plugins" -e MM_PLUGINSETTINGS_CLIENTDIRECTORY="$RUN/client/plugins" \
  -e MM_LOGSETTINGS_ENABLECONSOLE=true -e MM_LOGSETTINGS_ENABLEFILE=false \
  ubuntu:24.04 "$RUN/mattermost" >"$RUN/container.id"

for _ in {1..180}; do
  if curl -fsS http://127.0.0.1:8065/api/v4/system/ping >/dev/null 2>&1; then exit 0; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' niro-mattermost-server 2>/dev/null || true)" != true ]]; then docker logs --tail 100 niro-mattermost-server; exit 1; fi
  sleep 1
done
docker logs --tail 100 niro-mattermost-server
exit 1
