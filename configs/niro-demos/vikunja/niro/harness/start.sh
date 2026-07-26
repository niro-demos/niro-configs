#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NIRO_DIR="$ROOT_DIR/niro"
RUN_DIR="$NIRO_DIR/harness/run"
BIN_DIR="$RUN_DIR/bin"
LOG_DIR="$RUN_DIR/logs"
API_PORT="${VIKUNJA_NIRO_API_PORT:-3456}"
FRONTEND_PORT="${VIKUNJA_NIRO_FRONTEND_PORT:-4173}"
API_HOST="127.0.0.1"
API_BASE="http://$API_HOST:$API_PORT"
FRONTEND_BASE="http://localhost:$FRONTEND_PORT"
TESTING_TOKEN="${VIKUNJA_NIRO_TESTING_TOKEN:-niro-local-testing-token}"

mkdir -p "$BIN_DIR" "$LOG_DIR" "$RUN_DIR/files"

is_alive() {
	local pid_file="$1"
	[[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

wait_for_http() {
	local url="$1"
	local label="$2"
	local deadline=$((SECONDS + 90))
	while (( SECONDS < deadline )); do
		if curl -fsS "$url" >/dev/null 2>&1; then
			echo "$label ready at $url"
			return 0
		fi
		sleep 1
	done
	echo "$label did not become ready at $url" >&2
	return 1
}

ensure_pnpm() {
	if command -v pnpm >/dev/null 2>&1; then
		return
	fi
	if ! command -v corepack >/dev/null 2>&1; then
		echo "pnpm is not installed and corepack is unavailable" >&2
		return 1
	fi
	corepack prepare pnpm@11.15.1 --activate >/dev/null
}

run_pnpm() {
	if command -v pnpm >/dev/null 2>&1; then
		pnpm "$@"
		return
	fi
	corepack pnpm "$@"
}

if is_alive "$RUN_DIR/api.pid" && is_alive "$RUN_DIR/frontend.pid"; then
	wait_for_http "$API_BASE/api/v1/info" "API"
	wait_for_http "$FRONTEND_BASE" "Frontend"
	printf '%s\n' "$FRONTEND_BASE" > "$RUN_DIR/target-url"
	exit 0
fi

"$NIRO_DIR/harness/stop.sh" >/dev/null 2>&1 || true

ensure_pnpm
if [[ ! -d "$ROOT_DIR/frontend/node_modules" ]]; then
	echo "Installing frontend dependencies"
	(cd "$ROOT_DIR/frontend" && run_pnpm install --frozen-lockfile)
fi

echo "Building frontend assets required by the embedded API binary"
(cd "$ROOT_DIR/frontend" && run_pnpm build)

echo "Building Vikunja API from current checkout"
go build -tags osusergo -o "$BIN_DIR/vikunja" .

echo "Starting API on $API_BASE"
(
	cd "$ROOT_DIR"
	setsid env \
		VIKUNJA_SERVICE_INTERFACE="$API_HOST:$API_PORT" \
		VIKUNJA_SERVICE_PUBLICURL="$API_BASE/" \
		VIKUNJA_SERVICE_TESTINGTOKEN="$TESTING_TOKEN" \
		VIKUNJA_SERVICE_ROOTPATH="$RUN_DIR" \
		VIKUNJA_SERVICE_JWTSECRET="niro-local-jwt-secret-do-not-use-in-production" \
		VIKUNJA_SERVICE_ENABLEREGISTRATION=true \
		VIKUNJA_DATABASE_TYPE=sqlite \
		VIKUNJA_DATABASE_PATH="$RUN_DIR/vikunja.db" \
		VIKUNJA_FILES_BASEPATH="$RUN_DIR/files" \
		VIKUNJA_LOG_LEVEL=WARNING \
		VIKUNJA_MAILER_ENABLED=false \
		VIKUNJA_REDIS_ENABLED=false \
		VIKUNJA_RATELIMIT_NOAUTHLIMIT=1000 \
		"$BIN_DIR/vikunja" web \
		>"$LOG_DIR/api.log" 2>&1 </dev/null &
	echo $! > "$RUN_DIR/api.pid"
)
wait_for_http "$API_BASE/api/v1/info" "API"
wait_for_http "$API_BASE/api/v2/info" "API v2"
wait_for_http "$API_BASE/api/v2/health" "API health"

echo "Starting frontend on $FRONTEND_BASE"
(
	cd "$ROOT_DIR/frontend"
	setsid env \
		DEV_PROXY="$API_BASE" \
		VIKUNJA_FRONTEND_PORT="$FRONTEND_PORT" \
		"$ROOT_DIR/frontend/node_modules/.bin/vite" --host 0.0.0.0 --port "$FRONTEND_PORT" --strictPort \
		>"$LOG_DIR/frontend.log" 2>&1 </dev/null &
	echo $! > "$RUN_DIR/frontend.pid"
)
wait_for_http "$FRONTEND_BASE" "Frontend"

printf '%s\n' "$FRONTEND_BASE" > "$RUN_DIR/target-url"
printf 'API_URL=%s/api/v1\nFRONTEND_URL=%s\nTESTING_TOKEN=%s\n' "$API_BASE" "$FRONTEND_BASE" "$TESTING_TOKEN" > "$RUN_DIR/runtime.env"

echo "Niro target URL: $FRONTEND_BASE"
