#!/usr/bin/env bash
# stop: shut down the Juice Shop instance started by start.sh, if any.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

stop_app
