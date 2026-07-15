#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/../.." && pwd)
"$repo_root/niro/harness/stop.sh"
rm -rf "$repo_root/niro/harness/run/data"
"$repo_root/niro/harness/start.sh"
"$repo_root/niro/harness/seed.sh"
