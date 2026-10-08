# Shared helpers for the JobRunner acceptance tests. Source it, don't run it.
#
# Provides: config, sql/log/env_fail, preconditions (no stray workers, DB up, build, API),
# start_worker, a cleanup trap that stops everything the test started, and check/finish
# for PASS/FAIL reporting.
#
# Exit codes used by every test: 0 = pass, 1 = fail, 2 = environment problem / inconclusive.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB_CONTAINER="jobrunner-db"
API_URL="http://localhost:5200"
DB_CONN="Host=localhost;Port=5433;Database=jobrunner;Username=postgres;Password=postgres"
WORKER_BIN="JobRunner.Worker/bin/Debug/net10.0/JobRunner.Worker"
API_BIN="JobRunner.Api/bin/Debug/net10.0/JobRunner.Api"
WORKER_SRC="JobRunner.Worker/JobWorker.cs"
# Match a worker by how it was launched (anchored), never a shell/editor that mentions the path.
WORKER_PATTERN='^(\S*/JobRunner\.Worker|dotnet \S*JobRunner\.Worker\.dll|dotnet run --project \S*JobRunner\.Worker)( |$)'

TEST_NAME="$(basename "$0" .sh)"
LOG_DIR="$(mktemp -d -t "jobrunner-$TEST_NAME-XXXXXX")"
declare -A WORKER_PID=() # name -> pid
API_PID=""
RESULT="FAIL"
FAILURES=0

sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d jobrunner -tA -c "$1"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
env_fail() { log "ENVIRONMENT: $*"; RESULT="ENV"; exit 2; }
db_up() { sql 'SELECT 1' >/dev/null 2>&1; }

# Read a TimeSpan.FromSeconds(N) constant from JobWorker.cs so tests can't drift from it.
worker_const() {
    local v
    v=$(grep -oP "$1 = TimeSpan\.FromSeconds\(\K[0-9]+" "$WORKER_SRC" || true)
    [[ -n "$v" ]] || env_fail "could not read $1 from $WORKER_SRC"
    echo "$v"
}

start_worker() { # start_worker <name>; log in $LOG_DIR/<name>.log
    env ConnectionStrings__Default="$DB_CONN" \
        DOTNET_ENVIRONMENT=Production \
        Logging__Console__FormatterName=simple \
        Logging__Console__FormatterOptions__SingleLine=true \
        Logging__Console__FormatterOptions__ColorBehavior=Disabled \
        'Logging__LogLevel__Microsoft.EntityFrameworkCore=None' \
        "$WORKER_BIN" >"$LOG_DIR/$1.log" 2>&1 &
    WORKER_PID[$1]=$!
}

stop_worker() { # stop_worker <name>  (SIGTERM, then wait)
    local pid=${WORKER_PID[$1]:-}
    [[ -n "$pid" ]] || return 0
    kill -CONT "$pid" 2>/dev/null || true # in case a test SIGSTOPped it
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    unset "WORKER_PID[$1]"
}

wait_for_log() { # wait_for_log <worker> <regex> <timeout-secs>
    local deadline=$((SECONDS + $3))
    until grep -qE "$2" "$LOG_DIR/$1.log" 2>/dev/null; do
        ((SECONDS < deadline)) || return 1
        sleep 0.05
    done
}

cleanup() {
    local code=$?
    for name in "${!WORKER_PID[@]}"; do stop_worker "$name"; done
    if [[ -n "$API_PID" ]]; then
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
    fi
    # A test that stopped the DB must never leave it stopped.
    if [[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" != "true" ]]; then
        log "Restarting $DB_CONTAINER left stopped by the test"
        docker start "$DB_CONTAINER" >/dev/null || true
    fi
    if pgrep -f "$WORKER_PATTERN" >/dev/null; then
        log "WARNING: worker processes still alive after cleanup:"
        pgrep -af "$WORKER_PATTERN" || true
    fi
    if [[ "$RESULT" == "PASS" ]]; then rm -rf "$LOG_DIR"; else log "Logs kept in $LOG_DIR"; fi
    exit "$code"
}
trap cleanup EXIT
trap 'log "Interrupted"; exit 130' INT TERM

preconditions() { # preconditions [--no-api]
    log "=== Preconditions ==="
    if pgrep -f "$WORKER_PATTERN" >/dev/null; then
        pgrep -af "$WORKER_PATTERN"
        env_fail "worker processes are already running; kill them first"
    fi
    [[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" == "true" ]] \
        || env_fail "container $DB_CONTAINER is not running (docker compose up -d)"
    dotnet build JobRunner.slnx -v q -nologo >"$LOG_DIR/build.log" 2>&1 \
        || { cat "$LOG_DIR/build.log"; env_fail "build failed"; }
    [[ "${1:-}" == "--no-api" ]] && return 0
    if ! curl -sf -o /dev/null "$API_URL/api/jobs?pageSize=1"; then
        ConnectionStrings__Default="$DB_CONN" ASPNETCORE_URLS="$API_URL" \
            "$API_BIN" >"$LOG_DIR/api.log" 2>&1 &
        API_PID=$!
        for _ in $(seq 1 30); do
            curl -sf -o /dev/null "$API_URL/api/jobs?pageSize=1" && return 0
            kill -0 "$API_PID" 2>/dev/null || { cat "$LOG_DIR/api.log"; env_fail "API exited on startup"; }
            sleep 0.5
        done
        env_fail "API did not become ready"
    fi
}

post_job() { # post_job <json> -> prints HTTP status
    curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/api/jobs" \
        -H 'Content-Type: application/json' -d "$1"
}

check() { # check <description> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
        printf '  PASS  %-52s %s\n' "$1" "$2"
    else
        printf '  FAIL  %-52s got %s, expected %s\n' "$1" "$2" "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

finish() { # finish <summary>
    echo
    if [[ "$FAILURES" -eq 0 ]]; then
        RESULT="PASS"
        log "RESULT: PASS  $1"
        exit 0
    fi
    log "RESULT: FAIL  ($FAILURES assertion(s) failed) $1"
    exit 1
}
