#!/usr/bin/env sh
set -eu

. "$(dirname -- "$0")/common.sh"

write_env
compose exec -T rails bundle exec rails runner /app/niro/harness/seed_runner.rb
