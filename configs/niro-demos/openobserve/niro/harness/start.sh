#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
run_dir="$repo_root/niro/harness/run"
mkdir -p "$run_dir"

if [[ -f "$run_dir/openobserve.pid" ]] && kill -0 "$(cat "$run_dir/openobserve.pid")" 2>/dev/null \
  && [[ -f "$run_dir/nginx.pid" ]] && kill -0 "$(cat "$run_dir/nginx.pid")" 2>/dev/null; then
  curl --fail --silent --show-error http://127.0.0.1:5080/healthz >/dev/null
  exit 0
fi

web_hash=$(cd "$repo_root" && git ls-files -c -o --exclude-standard web | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
if [[ ! -f "$run_dir/web.hash" ]] || [[ "$(cat "$run_dir/web.hash")" != "$web_hash" ]] || [[ ! -f "$repo_root/web/dist/index.html" ]]; then
  cd "$repo_root/web"
  npm ci
  NODE_OPTIONS=--max-old-space-size=8192 npm run build
  echo "$web_hash" >"$run_dir/web.hash"
fi

cd "$repo_root"
protoc_bin=$(command -v protoc || true)
if [[ -z "$protoc_bin" ]]; then
  protoc_root="$run_dir/tools/protoc-21.12"
  if [[ ! -x "$protoc_root/bin/protoc" ]]; then
    mkdir -p "$run_dir/tools"
    curl --fail --location --silent --show-error \
      https://github.com/protocolbuffers/protobuf/releases/download/v21.12/protoc-21.12-linux-x86_64.zip \
      --output "$run_dir/tools/protoc.zip"
    unzip -q -o "$run_dir/tools/protoc.zip" -d "$protoc_root"
    rm -f "$run_dir/tools/protoc.zip"
  fi
  protoc_bin="$protoc_root/bin/protoc"
fi
PROTOC="$protoc_bin" PROTOC_INCLUDE="$(dirname "$(dirname "$protoc_bin")")/include" cargo build --bin openobserve --features profiling

export ZO_DATA_DIR="$run_dir/data/"
export ZO_LOCAL_MODE=true
export ZO_HTTP_PORT=5082
export ZO_ROOT_USER_EMAIL=root@niro.test
export ZO_ROOT_USER_PASSWORD='NiroRoot-2026!'
export ZO_TELEMETRY=false
export RUST_LOG=info
setsid nohup "$repo_root/target/debug/openobserve" >"$run_dir/openobserve.log" 2>&1 < /dev/null &
echo $! >"$run_dir/openobserve.pid"

for _ in $(seq 1 180); do
  if curl --fail --silent http://127.0.0.1:5082/healthz >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$(cat "$run_dir/openobserve.pid")" 2>/dev/null; then
    tail -200 "$run_dir/openobserve.log" >&2
    exit 1
  fi
  sleep 1
done

setsid /usr/sbin/nginx -c "$repo_root/niro/harness/nginx.conf" >"$run_dir/nginx-stdout.log" 2>&1 < /dev/null &
for _ in $(seq 1 30); do
  if curl --fail --silent http://127.0.0.1:5080/healthz >/dev/null 2>&1 \
    && curl --fail --silent http://127.0.0.1:5080/web/ >/dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done
tail -200 "$run_dir/openobserve.log" "$run_dir/nginx-error.log" >&2
exit 1
