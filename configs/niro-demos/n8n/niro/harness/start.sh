#!/usr/bin/env bash
# Build-then-run "start" for a Niro-owned n8n target: serves the current
# checkout (packages/cli + packages/frontend/editor-ui dist output already
# produced by `pnpm build`), starts the full service graph (single n8n
# process serves both the editor UI and the REST/public API on N8N_PORT —
# no separate webhook/worker process needed for this surface), and blocks
# until /healthz is green. Idempotent: a second call is a no-op if already up.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

is_up() {
	curl -fsS --max-time 2 "$(readiness_url)" >/dev/null 2>&1
}

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null && is_up; then
	echo "n8n already running (pid $(cat "$PID_FILE")) at $N8N_BASE_URL"
	exit 0
fi

# Stale pid file (process gone) — clean it up before relaunching.
if [[ -f "$PID_FILE" ]] && ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
	rm -f "$PID_FILE"
fi

if [[ ! -d "$REPO_ROOT/packages/cli/dist" ]]; then
	echo "packages/cli/dist is missing — run 'pnpm build' (or 'pnpm agent:setup build') from the repo root first." >&2
	exit 1
fi

cd "$REPO_ROOT"
: > "$LOG_FILE"
# packages/cli/bin/n8n with no subcommand defaults to `start`.
nohup ./packages/cli/bin/n8n >>"$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
disown

echo "Starting n8n (pid $(cat "$PID_FILE")), logging to $LOG_FILE ..."

ATTEMPTS=90
for ((i = 1; i <= ATTEMPTS; i++)); do
	if is_up; then
		echo "n8n is healthy at $N8N_BASE_URL"
		exit 0
	fi
	if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
		echo "n8n process exited before becoming healthy. Tail of $LOG_FILE:" >&2
		tail -n 80 "$LOG_FILE" >&2 || true
		exit 1
	fi
	sleep 2
done

echo "n8n did not become healthy within $((ATTEMPTS * 2))s. Tail of $LOG_FILE:" >&2
tail -n 80 "$LOG_FILE" >&2 || true
exit 1
