#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
"$here/stop.sh"
rm -rf "$here/run/home"
mkdir -p "$here/run/home"
"$here/start.sh"
"$here/seed.sh"
