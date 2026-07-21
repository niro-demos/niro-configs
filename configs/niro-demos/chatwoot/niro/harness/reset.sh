#!/usr/bin/env sh
set -eu

. "$(dirname -- "$0")/common.sh"

write_env
compose up -d postgres redis mailhog
compose stop rails sidekiq >/dev/null 2>&1 || true
compose run --rm rails sh -lc 'DISABLE_DATABASE_ENVIRONMENT_CHECK=1 bundle exec rails db:drop db:create db:chatwoot_prepare'
compose up -d rails sidekiq vite
wait_for_http "http://localhost:${CHATWOOT_RAILS_PORT}/health" "Rails"
"$HARNESS_DIR/seed.sh"
