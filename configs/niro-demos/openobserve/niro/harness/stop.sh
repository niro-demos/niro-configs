#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
nginx_pid_file="$repo_root/niro/harness/run/nginx.pid"
if [[ -f "$nginx_pid_file" ]]; then
  nginx_pid=$(cat "$nginx_pid_file")
  if kill -0 "$nginx_pid" 2>/dev/null; then
    kill "$nginx_pid"
    for _ in $(seq 1 10); do
      kill -0 "$nginx_pid" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -f "$nginx_pid_file"
fi
pid_file="$repo_root/niro/harness/run/openobserve.pid"
if [[ ! -f "$pid_file" ]]; then
  exit 0
fi
pid=$(cat "$pid_file")
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$pid_file"
