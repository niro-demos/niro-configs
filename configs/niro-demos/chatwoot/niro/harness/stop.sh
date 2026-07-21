#!/usr/bin/env sh
set -eu

. "$(dirname -- "$0")/common.sh"

compose down --remove-orphans
