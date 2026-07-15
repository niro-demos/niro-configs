#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN="$HERE/run"
[[ -s "$RUN/golden.sql" ]] || { echo "missing golden seed snapshot; run seed.sh first" >&2; exit 1; }
docker rm -f niro-mattermost-server >/dev/null 2>&1 || true
docker exec niro-mattermost-postgres dropdb -U mmuser --if-exists mattermost
docker exec niro-mattermost-postgres createdb -U mmuser mattermost
docker exec -i niro-mattermost-postgres psql -U mmuser -d mattermost <"$RUN/golden.sql" >/dev/null
"$HERE/start.sh"
"$HERE/seed.sh"
