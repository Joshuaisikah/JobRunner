#!/usr/bin/env bash
# Acceptance test: `kill -9` a worker mid-job -> that job is re-run after the stale timeout.
#
# Scenario:
#   1. Worker A claims the only job and starts executing it.
#   2. A is SIGKILLed while the handler is running (no shutdown code runs).
#   3. The job is left in Running, owned by a dead worker.
#   4. Worker B starts. Once the claim is older than StaleTimeout, B reclaims and runs it.
#
# Asserts:
#   - A was really mid-job when killed: it had logged "Executing job 1" and the row was
#     still Running afterwards (A's completion never landed)
#   - A is really dead (we kill the worker binary itself, not a `dotnet run` wrapper)
#   - B reclaimed it (log), re-executed it (log), and it ended Succeeded
#   - not early:  B's claim happened >= StaleTimeout after A's claim
#   - not late:   the job succeeded within StaleTimeout + ReclaimInterval + slack of A's claim
#   - Attempts = 2 and FenceToken = 2 (one claim each, the reclaim bumped the token)
#
# Usage:   ./crash_test.sh            (from the JobRunner directory)
# Exit:    0 = pass, 1 = fail, 2 = environment problem / inconclusive (test did not run)

set -euo pipefail
cd "$(dirname "$0")"

DB_CONTAINER="jobrunner-db"
API_URL="http://localhost:5200"
DB_CONN="Host=localhost;Port=5433;Database=jobrunner;Username=postgres;Password=postgres"
WORKER_BIN="JobRunner.Worker/bin/Debug/net10.0/JobRunner.Worker"
API_BIN="JobRunner.Api/bin/Debug/net10.0/JobRunner.Api"
WORKER_SRC="JobRunner.Worker/JobWorker.cs"
# See concurrency_test.sh for why this is anchored.
WORKER_PATTERN='^(\S*/JobRunner\.Worker|dotnet \S*JobRunner\.Worker\.dll|dotnet run --project \S*JobRunner\.Worker)( |$)'
SLACK_SECS=15 # worker startup + handler run time + polling granularity

LOG_DIR="$(mktemp -d -t jobrunner-crash-XXXXXX)"
WORKER_PIDS=()
API_PID=""
RESULT="FAIL"

# ---------------------------------------------------------------- helpers
sql() { docker exec -i "$DB_CONTAINER" psql -U postgres -d jobrunner -tA -c "$1"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
env_fail() { log "ENVIRONMENT: $*"; RESULT="ENV"; exit 2; }
job_status() { sql 'SELECT "Status" FROM jobs WHERE "Id" = 1;'; }

start_worker() { # start_worker <name>  -> appends pid to WORKER_PIDS, log in $LOG_DIR/<name>.log
    env ConnectionStrings__Default="$DB_CONN" \
        DOTNET_ENVIRONMENT=Production \
        Logging__Console__FormatterName=simple \
        Logging__Console__FormatterOptions__SingleLine=true \
        Logging__Console__FormatterOptions__ColorBehavior=Disabled \
        'Logging__LogLevel__Microsoft.EntityFrameworkCore=Warning' \
        "$WORKER_BIN" >"$LOG_DIR/$1.log" 2>&1 &
    WORKER_PIDS+=($!)
}

cleanup() {
    local code=$?
    for pid in "${WORKER_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    for pid in "${WORKER_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    if [[ -n "$API_PID" ]]; then
        kill "$API_PID" 2>/dev/null || true
        wait "$API_PID" 2>/dev/null || true
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

# ---------------------------------------------------------------- preconditions
log "=== 0. Preconditions ==="

if pgrep -f "$WORKER_PATTERN" >/dev/null; then
    pgrep -af "$WORKER_PATTERN"
    env_fail "worker processes are already running; kill them first (pkill -f JobRunner.Worker)"
fi

[[ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" == "true" ]] \
    || env_fail "container $DB_CONTAINER is not running (docker compose up -d)"

# Read the timings from the worker source so this test can't silently drift from it.
STALE_SECS=$(grep -oP 'StaleTimeout = TimeSpan\.FromSeconds\(\K[0-9]+' "$WORKER_SRC" || true)
RECLAIM_SECS=$(grep -oP 'ReclaimInterval = TimeSpan\.FromSeconds\(\K[0-9]+' "$WORKER_SRC" || true)
[[ -n "$STALE_SECS" && -n "$RECLAIM_SECS" ]] \
    || env_fail "could not read StaleTimeout / ReclaimInterval from $WORKER_SRC"
log "StaleTimeout=${STALE_SECS}s ReclaimInterval=${RECLAIM_SECS}s (from $WORKER_SRC)"

log "Building"
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
log "=== 1. Seeding one job ==="
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null
# ResizeImage: the slower handler (1.5s), giving the widest window to kill mid-execution.
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API_URL/api/jobs" \
    -H 'Content-Type: application/json' \
    -d '{"jobType":"ResizeImage","payload":{"imageUrl":"http://example.com/a.png","width":10,"height":10}}')
[[ "$code" == "201" ]] || env_fail "seeding returned HTTP $code"

# ---------------------------------------------------------------- crash worker A
log "=== 2. Worker A: claim and start executing ==="
start_worker worker-a
PID_A=${WORKER_PIDS[0]}

for _ in $(seq 1 600); do # up to 30s at 50ms
    grep -q 'Executing job 1 ' "$LOG_DIR/worker-a.log" 2>/dev/null && break
    kill -0 "$PID_A" 2>/dev/null || { tail -n 20 "$LOG_DIR/worker-a.log"; env_fail "worker A exited before executing the job"; }
    sleep 0.05
done
grep -q 'Executing job 1 ' "$LOG_DIR/worker-a.log" || env_fail "worker A never started executing job 1"

log "=== 3. kill -9 worker A (pid $PID_A) mid-execution ==="
kill -9 "$PID_A"
wait "$PID_A" 2>/dev/null || true
WORKER_PIDS=()

status_after_kill=$(job_status)
if [[ "$status_after_kill" != "Running" ]]; then
    # A finished the handler before the kill landed: the scenario never happened.
    env_fail "INCONCLUSIVE: job was '$status_after_kill' right after the kill (A finished first); re-run"
fi
claimed_a=$(sql 'SELECT extract(epoch FROM "ClaimedAt") FROM jobs WHERE "Id" = 1;')
log "Job left in Running by dead worker A"

# ---------------------------------------------------------------- recover with worker B
deadline_secs=$((STALE_SECS + RECLAIM_SECS + SLACK_SECS))
log "=== 4. Worker B: must reclaim after ${STALE_SECS}s, finish within ${deadline_secs}s of A's claim ==="
start_worker worker-b
PID_B=${WORKER_PIDS[0]}

while :; do
    status=$(job_status)
    [[ "$status" == "Succeeded" || "$status" == "Failed" ]] && break
    kill -0 "$PID_B" 2>/dev/null || { tail -n 20 "$LOG_DIR/worker-b.log"; log "FAIL: worker B died"; exit 1; }
    since_claim=$(sql "SELECT floor(extract(epoch FROM now()) - $claimed_a);")
    if ((since_claim > deadline_secs)); then
        log "FAIL: job still '$status' ${since_claim}s after A's claim (deadline ${deadline_secs}s)"
        exit 1
    fi
    log "status: $status (${since_claim}s since A's claim)"
    sleep 2
done
finished_after=$(sql "SELECT round(extract(epoch FROM now()) - $claimed_a);")

kill "$PID_B" 2>/dev/null || true
wait "$PID_B" 2>/dev/null || true
WORKER_PIDS=()

# ---------------------------------------------------------------- assert
log "=== 5. Assertions ==="
failures=0
check() { # check <description> <actual> <expected>
    if [[ "$2" == "$3" ]]; then
        printf '  PASS  %-48s %s\n' "$1" "$2"
    else
        printf '  FAIL  %-48s got %s, expected %s\n' "$1" "$2" "$3"
        failures=$((failures + 1))
    fi
}

reclaim_gap=$(sql "SELECT floor(extract(epoch FROM \"ClaimedAt\") - $claimed_a) FROM jobs WHERE \"Id\" = 1;")
check "status right after kill -9"                    "$status_after_kill" "Running"
check "worker A completed the job"                    "$(grep -c 'Successfully completed job 1' "$LOG_DIR/worker-a.log" || true)" "0"
check "worker B reclaimed job 1"                      "$(grep -c 'Reclaimed stale job 1 ' "$LOG_DIR/worker-b.log" || true)" "1"
check "worker B executed job 1"                       "$(grep -c 'Executing job 1 ' "$LOG_DIR/worker-b.log" || true)" "1"
check "final status"                                  "$(job_status)" "Succeeded"
check "Attempts"                                      "$(sql 'SELECT "Attempts" FROM jobs WHERE "Id" = 1;')" "2"
check "FenceToken"                                    "$(sql 'SELECT "FenceToken" FROM jobs WHERE "Id" = 1;')" "2"
check "reclaimed no earlier than StaleTimeout"        "$( ((reclaim_gap >= STALE_SECS)) && echo yes || echo "no (${reclaim_gap}s)")" "yes"
check "LockedBy cleared"                              "$(sql 'SELECT coalesce("LockedBy", '"'"'<null>'"'"') FROM jobs WHERE "Id" = 1;')" "<null>"
echo "        reclaimed ${reclaim_gap}s after A's claim, succeeded ${finished_after}s after A's claim"

echo
if [[ "$failures" -eq 0 ]]; then
    RESULT="PASS"
    log "RESULT: PASS  (reclaimed after ${reclaim_gap}s, done after ${finished_after}s; stale=${STALE_SECS}s)"
    exit 0
else
    log "RESULT: FAIL  ($failures assertion(s) failed)"
    exit 1
fi
