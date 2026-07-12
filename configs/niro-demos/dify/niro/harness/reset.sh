#!/usr/bin/env bash
# Restore a clean baseline: stop everything, wipe the middleware's
# persisted data (Postgres, Redis, Weaviate, plugin_daemon volumes -- the
# same reset e2e/scripts/setup.ts reset performs for the project's own
# suite), then rebuild the stack and re-seed from the committed generator
# so the DB and the regenerated credentials.yaml/fixtures.yaml describe the
# same logical actors again.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=support/common.sh
source ./support/common.sh

log "Stopping application processes..."
for name in web celery api; do
  stop_background "$name"
done

log "Wiping middleware data volumes and stopping middleware..."
if ! e2e_tsx ./scripts/setup.ts reset; then
  # Postgres (and other middleware containers) write into the bind-mounted
  # docker/volumes/* directories as their in-container user, which usually
  # isn't the host user running this script -- e2e's own reset (a plain
  # unprivileged `rm`) can hit EACCES on those root/container-owned files.
  # Retry with sudo, scoped to exactly the same paths e2e's reset targets.
  log "Project reset script could not remove docker/volumes (likely root/container-owned files left by Postgres et al). Retrying with sudo..."
  if command -v sudo >/dev/null 2>&1; then
    # Remove the (possibly root-owned) parent dirs entirely; `docker compose
    # up` recreates bind-mount source directories automatically (as root, via
    # the daemon) when they're missing, so no unprivileged mkdir is needed.
    sudo rm -rf \
      "$DOCKER_DIR/volumes/db" \
      "$DOCKER_DIR/volumes/redis" \
      "$DOCKER_DIR/volumes/weaviate" \
      "$DOCKER_DIR/volumes/plugin_daemon"
  else
    die "docker/volumes cleanup failed and sudo is unavailable to retry; clean up $DOCKER_DIR/volumes manually and re-run."
  fi
fi

log "Clearing seed.sh's local state markers (e.g. Tenant B credentials) so they can't drift from the wiped DB..."
rm -rf "${STATE_DIR:?}"/*

log "Rebuilding and starting the stack on a clean baseline..."
./start.sh

log "Re-seeding deterministic tenants, accounts, and fixtures..."
./seed.sh

log "Reset complete."
