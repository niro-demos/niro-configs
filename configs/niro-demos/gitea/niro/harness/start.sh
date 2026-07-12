#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
run_dir="$repo_root/niro/harness/run"
url=http://127.0.0.1:3300
container_name=niro-gitea-runtime
mkdir -p "$run_dir/custom/conf" "$run_dir/data" "$run_dir/log" "$run_dir/repositories"

if [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" == true ]]; then
  curl --fail --silent --show-error "$url/api/healthz" >/dev/null
  exit 0
fi

cd "$repo_root"
make generate-backend
CGO_ENABLED=0 go build -tags 'bindata sqlite sqlite_unlock_notify' -o "$run_dir/gitea" .

cat >"$run_dir/custom/conf/app.ini" <<EOF
APP_NAME = Gitea Niro Pentest
RUN_MODE = prod

[server]
PROTOCOL = http
HTTP_ADDR = 0.0.0.0
HTTP_PORT = 3300
ROOT_URL = $url/
APP_DATA_PATH = $run_dir/data
DISABLE_SSH = true

[database]
DB_TYPE = sqlite3
PATH = $run_dir/gitea.db

[repository]
ROOT = $run_dir/repositories

[security]
INSTALL_LOCK = true
SECRET_KEY = niro-local-secret-key-change-only-in-harness
INTERNAL_TOKEN = 4f1da126dcb77205fdc0c2d8b589c03fa3e51f540de013fb90266f339df7592d

[service]
DISABLE_REGISTRATION = false
REQUIRE_SIGNIN_VIEW = false
ENABLE_NOTIFY_MAIL = false
REGISTER_EMAIL_CONFIRM = false
ENABLE_CAPTCHA = false
DEFAULT_ALLOW_CREATE_ORGANIZATION = true

[mailer]
ENABLED = false

[log]
MODE = file
LEVEL = Info
ROOT_PATH = $run_dir/log
EOF

docker build --quiet -t niro-gitea-runtime "$repo_root/niro/harness" >/dev/null
docker rm -f "$container_name" >/dev/null 2>&1 || true
docker run --detach --name "$container_name" --network host \
  --user "$(id -u):$(id -g)" \
  --volume "$run_dir:$run_dir" --workdir "$run_dir" \
  --env HOME="$run_dir/data/home" \
  --env GITEA_WORK_DIR="$run_dir" --env GITEA_CUSTOM="$run_dir/custom" \
  --entrypoint "$run_dir/gitea" niro-gitea-runtime \
  web --config "$run_dir/custom/conf/app.ini" >"$run_dir/gitea.container"

for _ in $(seq 1 120); do
  if curl --fail --silent "$url/api/healthz" >/dev/null 2>&1; then
    exit 0
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" != true ]]; then
    docker logs "$container_name" >&2
    exit 1
  fi
  sleep 0.25
done
echo "Gitea did not become healthy at $url" >&2
exit 1
