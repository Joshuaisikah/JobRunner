#!/usr/bin/env bash
# Acceptance test: N workers, M jobs -> every job executed exactly once.
#
# What it proves, and how:
#   - claims:      every job has Attempts = 1 in the DB
#   - executions:  every job id appears in exactly one "Executing job <id>" log line
#                  across all worker logs (counted outside the DB, so a job that is
#                  claimed once but run twice still shows up as a duplicate)
#   - concurrency: every worker executed at least one job
#   - no recovery paths fired: no stale reclaims, no lost fence tokens, no failures
#
# Usage:   ./concurrency_test.sh            (from the JobRunner directory)
# Env:     WORKERS=3 TOTAL_JOBS=200 MAX_WAIT=180 KEEP_LOGS=1
# Exit:    0 = pass, 1 = fail, 2 = environment problem (test did not run)

set -euo pipefail
cd "$(dirname "$0")"

WORKERS="${WORKERS:-3}"
TOTAL_JOBS="${TOTAL_JOBS:-200}"
MAX_WAIT="${MAX_WAIT:-180}"
KEEP_LOGS="${KEEP_LOGS:-0}"

DB_CONTAINER="jobrunner-db"
API_URL="http://localhost:5200"
DB_CONN="Host=localhost;Port=5433;Database=jobrunner;Username=postgres;Password=postgres"
WORKER_BIN="JobRunner.Worker/bin/Debug/net10.0/JobRunner.Worker"
API_BIN="JobRunner.Api/bin/Debug/net10.0/JobRunner.Api"
# Matches a worker process by how it was *launched* (anchored at the start of its command
# line): the built binary, `dotnet <dll>`, or a `dotnet run` wrapper. Anchoring matters:
# an unanchored pattern also matches any shell, editor or tail whose arguments merely
# mention the path.
WORKER_PATTERN='^(\S*/JobRunner\.Worker|dotnet \S*JobRunner\.Worker\.dll|dotnet run --project \S*JobRunner\.Worker)( |$)'

LOG_DIR="$(mktemp -d -t jobrunner-conc-XXXXXX)"
WORKER_PIDS=()
API_PID=""
RESULT="FAIL"

# ---------------------------------------------------------------- helpers
sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d jobrunner -tA -c "$1"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
env_fail() { log "ENVIRONMENT: $*"; RESULT="ENV"; exit 2; }

cleanup() {
    local code=$?
    for pid in "${WORKER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${WORKER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    if [[ -n "$API_PID" ]]; then
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
    fi
    # Belt and braces: nothing this script started may outlive it.
    if pgrep -f "$WORKER_PATTERN" >/dev/null; then
        log "WARNING: worker processes still alive after cleanup:"
        pgrep -af "$WORKER_PATTERN" || true
    fi
    if [[ "$RESULT" == "PASS" && "$KEEP_LOGS" != "1" ]]; then
        rm -rf "$LOG_DIR"
    else
        log "Logs kept in $LOG_DIR"
    fi
    exit "$code"
}
trap cleanup EXIT
trap 'log "Interrupted"; exit 130' INT TERM

# ---------------------------------------------------------------- preconditions
log "=== 0. Preconditions ==="

if pgrep -f "$WORKER_PATTERN" >/dev/null; then
    pgrep -af "$WORKER_PATTERN"
    env_fail "worker processes are already running; kill them first (pkill -f JobRunner.Worker)"
fi

[[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" == "true" ]] \
    || env_fail "container $DB_CONTAINER is not running (docker compose up -d)"

log "Building (once, so all workers run the same binary)"
dotnet build JobRunner.slnx -v q -nologo >"$LOG_DIR/build.log" 2>&1 \
    || { cat "$LOG_DIR/build.log"; env_fail "build failed"; }

if curl -sf -o /dev/null "$API_URL/api/jobs?pageSize=1"; then
    log "Using API already running at $API_URL"
else
    log "Starting API"
    ConnectionStrings__Default="$DB_CONN" ASPNETCORE_URLS="$API_URL" \
        "$API_BIN" >"$LOG_DIR/api.log" 2>&1 &
    API_PID=$!
    for _ in $(seq 1 30); do
        curl -sf -o /dev/null "$API_URL/api/jobs?pageSize=1" && break
        kill -0 "$API_PID" 2>/dev/null || { cat "$LOG_DIR/api.log"; env_fail "API exited on startup"; }
        sleep 0.5
    done
    curl -sf -o /dev/null "$API_URL/api/jobs?pageSize=1" || env_fail "API did not become ready"
fi

# ---------------------------------------------------------------- seed
log "=== 1. Resetting jobs table ==="
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null

log "=== 2. Seeding $TOTAL_JOBS jobs via API ==="
seed_failures=0
for ((i = 1; i <= TOTAL_JOBS; i++)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/api/jobs" \
        -H 'Content-Type: application/json' \
        -d "{\"jobType\":\"SendEmail\",\"payload\":{\"to\":\"user$i@example.com\",\"subject\":\"s\",\"body\":\"b\"}}")
    [[ "$code" == "201" ]] || seed_failures=$((seed_failures + 1))
done
seeded=$(sql 'SELECT COUNT(*) FROM jobs;')
[[ "$seed_failures" -eq 0 && "$seeded" -eq "$TOTAL_JOBS" ]] \
    || env_fail "seeding failed: $seed_failures non-201 responses, $seeded rows in table"

# ---------------------------------------------------------------- run
log "=== 3. Launching $WORKERS workers ==="
for ((w = 1; w <= WORKERS; w++)); do
    # Run the binary directly so $! is the worker itself, not a `dotnet run` wrapper.
    env ConnectionStrings__Default="$DB_CONN" \
        DOTNET_ENVIRONMENT=Production \
        Logging__Console__FormatterName=simple \
        Logging__Console__FormatterOptions__SingleLine=true \
        Logging__Console__FormatterOptions__ColorBehavior=Disabled \
        'Logging__LogLevel__Microsoft.EntityFrameworkCore=Warning' \
        "$WORKER_BIN" >"$LOG_DIR/worker-$w.log" 2>&1 &
    WORKER_PIDS+=($!)
done
log "Worker PIDs: ${WORKER_PIDS[*]}"

log "=== 4. Waiting for the queue to drain (max ${MAX_WAIT}s) ==="
start=$SECONDS
while :; do
    remaining=$(sql "SELECT COUNT(*) FROM jobs WHERE \"Status\" IN ('Pending','Running');")
    [[ "$remaining" -eq 0 ]] && break

    for ((w = 0; w < WORKERS; w++)); do
        kill -0 "${WORKER_PIDS[$w]}" 2>/dev/null || {
            tail -n 20 "$LOG_DIR/worker-$((w + 1)).log"
            log "FAIL: worker $((w + 1)) (pid ${WORKER_PIDS[$w]}) died during the run"
            exit 1
        }
    done

    elapsed=$((SECONDS - start))
    if ((elapsed >= MAX_WAIT)); then
        log "FAIL: timed out after ${elapsed}s with $remaining jobs still Pending/Running"
        exit 1
    fi
    log "remaining: $remaining (${elapsed}s)"
    sleep 2
done
drain_secs=$((SECONDS - start))
log "Queue drained in ${drain_secs}s"

log "=== 5. Stopping workers ==="
for pid in "${WORKER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
for pid in "${WORKER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
WORKER_PIDS=()

# ---------------------------------------------------------------- assert
log "=== 6. Assertions ==="
failures=0
check() { # check <description> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
        printf '  PASS  %-46s %s\n' "$1" "$2"
    else
        printf '  FAIL  %-46s got %s, expected %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

# Database view
check "jobs in table"                    "$(sql 'SELECT COUNT(*) FROM jobs;')" "$TOTAL_JOBS"
check "jobs Succeeded"                   "$(sql "SELECT COUNT(*) FROM jobs WHERE \"Status\"='Succeeded';")" "$TOTAL_JOBS"
check "jobs claimed more than once"      "$(sql 'SELECT COUNT(*) FROM jobs WHERE "Attempts" <> 1;')" "0"
check "jobs with FenceToken <> 1"        "$(sql 'SELECT COUNT(*) FROM jobs WHERE "FenceToken" <> 1;')" "0"

# Execution view, from the workers' own logs
cat "$LOG_DIR"/worker-*.log | grep -oE 'Executing job [0-9]+ ' | awk '{print $3}' | sort -n >"$LOG_DIR/executed.txt" || true
sql 'SELECT "Id" FROM jobs ORDER BY "Id";' >"$LOG_DIR/expected.txt"

executions=$(wc -l <"$LOG_DIR/executed.txt")
duplicates=$(uniq -d "$LOG_DIR/executed.txt" | wc -l)
missing=$(comm -23 <(sort "$LOG_DIR/expected.txt") <(sort -u "$LOG_DIR/executed.txt") | wc -l)
check "handler executions (log lines)"   "$executions" "$TOTAL_JOBS"
check "jobs executed more than once"     "$duplicates" "0"
check "jobs never executed"              "$missing" "0"
if [[ "$duplicates" -gt 0 ]]; then
    echo "        duplicated ids: $(uniq -d "$LOG_DIR/executed.txt" | head -20 | tr '\n' ' ')"
fi

# Concurrency actually happened
idle_workers=0
dist=""
for ((w = 1; w <= WORKERS; w++)); do
    n=$(grep -cE 'Executing job [0-9]+ ' "$LOG_DIR/worker-$w.log" || true)
    dist+="w$w=$n "
    [[ "$n" -gt 0 ]] || idle_workers=$((idle_workers + 1))
done
check "workers that executed nothing"    "$idle_workers" "0"
echo "        distribution: $dist"

# Recovery paths must not have fired in a clean run
check "stale reclaims"                   "$(cat "$LOG_DIR"/worker-*.log | grep -c 'Reclaimed stale job' || true)" "0"
check "lost fence tokens"                "$(cat "$LOG_DIR"/worker-*.log | grep -c 'Lost fence token' || true)" "0"
check "handler failures"                 "$(cat "$LOG_DIR"/worker-*.log | grep -c 'Execution failed for job' || true)" "0"
check "worker main-loop errors"          "$(cat "$LOG_DIR"/worker-*.log | grep -c 'Error occurred in worker main loop' || true)" "0"

echo
if [[ "$failures" -eq 0 ]]; then
    RESULT="PASS"
    log "RESULT: PASS  ($WORKERS workers, $TOTAL_JOBS jobs, drained in ${drain_secs}s, $dist)"
    exit 0
else
    log "RESULT: FAIL  ($failures assertion(s) failed)"
    exit 1
fi
