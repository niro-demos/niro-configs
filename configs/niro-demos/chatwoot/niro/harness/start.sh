#!/usr/bin/env sh
set -eu

. "$(dirname -- "$0")/common.sh"

write_env
compose build base
compose up -d --build postgres redis mailhog

until compose exec -T postgres pg_isready -U postgres -d chatwoot_niro >/dev/null 2>&1; do
  sleep 2
done

compose run --rm rails bundle exec rails db:chatwoot_prepare
compose up -d --build rails sidekiq vite

wait_for_http "http://localhost:${CHATWOOT_RAILS_PORT}/health" "Rails"
wait_for_http "http://localhost:${CHATWOOT_VITE_PORT}/vite-dev/@vite/client" "Vite"

"$HARNESS_DIR/seed.sh"

echo "Chatwoot Niro runtime is serving http://localhost:${CHATWOOT_RAILS_PORT}"
