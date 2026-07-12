#!/usr/bin/env bash
set -euo pipefail

harness_dir=$(cd "$(dirname "$0")" && pwd)
"$harness_dir/stop.sh"
rm -rf "$harness_dir/run"
"$harness_dir/start.sh"
"$harness_dir/seed.sh"
