#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUN="$ROOT/niro/harness/run"
mkdir -p "$RUN"

if [[ "$(docker inspect -f '{{.State.Running}}' casdoor-niro 2>/dev/null || true)" == "true" ]]; then
  curl -fsS http://127.0.0.1:8000/ >/dev/null
  exit 0
fi

if [[ ! -d "$ROOT/web/build" ]]; then
  (cd "$ROOT/web" && yarn install --frozen-lockfile && yarn build)
fi
(cd "$ROOT" && go build -o "$RUN/server" ./main.go)

cp "$ROOT/niro/harness/app.conf" "$RUN/app.conf"
sed -i "s|__DB_PATH__|/workspace/niro/harness/run/casdoor.db|g; s|__INIT_PATH__|/workspace/niro/harness/init_data.json|g" "$RUN/app.conf"
docker rm -f casdoor-niro-mysql >/dev/null 2>&1 || true
mkdir -p "$RUN/mysql"
docker run -d --name casdoor-niro-mysql --network host \
  -e MYSQL_ROOT_PASSWORD=niro-mysql-2026 -e MYSQL_DATABASE=casdoor \
  -v "$RUN/mysql:/var/lib/mysql" mysql:8.0.25 >/dev/null
for _ in $(seq 1 120); do
  if docker exec casdoor-niro-mysql mysqladmin ping -h 127.0.0.1 -uroot -pniro-mysql-2026 --silent >/dev/null 2>&1; then break; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' casdoor-niro-mysql 2>/dev/null || true)" != "true" ]]; then docker logs casdoor-niro-mysql >&2; exit 1; fi
  sleep 1
done
docker exec casdoor-niro-mysql mysqladmin ping -h 127.0.0.1 -uroot -pniro-mysql-2026 --silent >/dev/null
docker rm -f casdoor-niro >/dev/null 2>&1 || true
docker run -d --name casdoor-niro --network host --workdir /workspace \
  -v "$ROOT:/workspace" ubuntu:24.04 \
  /workspace/niro/harness/run/server -config /workspace/niro/harness/run/app.conf >/dev/null

for _ in $(seq 1 120); do
  if curl -fsS http://127.0.0.1:8000/ >/dev/null 2>&1; then exit 0; fi
  if [[ "$(docker inspect -f '{{.State.Running}}' casdoor-niro 2>/dev/null || true)" != "true" ]]; then docker logs casdoor-niro >&2; exit 1; fi
  sleep 1
done
docker logs casdoor-niro >&2
exit 1
