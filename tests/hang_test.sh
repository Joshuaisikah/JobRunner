#!/usr/bin/env bash
# Criterion 4: a worker that hangs past the timeout CANNOT write its result afterwards.
#
# A "hang" is simulated with SIGSTOP: worker A is frozen mid-job (a GC pause, a VM pause,
# a stuck syscall all look like this from outside). Nothing in A runs, heartbeat included.
#
#   1. A claims job 1 and starts executing it            -> SIGSTOP A
#   2. A's lease goes stale; worker B reclaims and completes job 1 (token 2)
#   3. SIGCONT A: A wakes up still holding token 1 and tries to finish
#   4. The row must still show B's result: A's late write (complete OR fail) must not land
source "$(dirname "$0")/lib.sh"

STALE=$(worker_const StaleTimeout)
RECLAIM=$(worker_const ReclaimInterval)
preconditions

log "=== 1. Seed one job; worker A starts executing it ==="
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null
code=$(post_job '{"jobType":"ResizeImage","payload":{"imageUrl":"http://x/a.png","width":1,"height":1}}')
[[ "$code" == "201" ]] || env_fail "seeding returned HTTP $code"
start_worker a
wait_for_log a 'Executing job 1 ' 30 || env_fail "worker A never started executing job 1"

kill -STOP "${WORKER_PID[a]}"
[[ "$(sql 'SELECT "Status" FROM jobs WHERE "Id"=1;')" == "Running" ]] \
    || env_fail "INCONCLUSIVE: A finished job 1 before it was frozen; re-run"
log "Worker A frozen mid-job (SIGSTOP)"

log "=== 2. Worker B must reclaim and complete job 1 ==="
start_worker b
deadline=$((SECONDS + STALE + 2 * RECLAIM + 15))
until [[ "$(sql 'SELECT "Status" FROM jobs WHERE "Id"=1;')" == "Succeeded" ]]; do
    ((SECONDS < deadline)) || { log "FAIL: B never completed job 1"; exit 1; }
    sleep 1
done
stop_worker b
row_before=$(sql 'SELECT "Status"||'"'"'|'"'"'||"FenceToken"||'"'"'|'"'"'||"Attempts"||'"'"'|'"'"'||coalesce("LastError",'"'"''"'"') FROM jobs WHERE "Id"=1;')
log "B completed job 1; row = $row_before"

log "=== 3. Wake worker A (SIGCONT) and let it try to finish ==="
kill -CONT "${WORKER_PID[a]}"
# A needs: the rest of its handler (<1.5s) + one heartbeat tick (<=10s) to notice.
wait_for_log a 'Lost fence token ownership for job 1|lease lost|Lost lease on job 1|Successfully completed job 1|Execution failed for job 1|timed out' 20 || true
sleep 2
stop_worker a

log "=== 4. Assertions ==="
row_after=$(sql 'SELECT "Status"||'"'"'|'"'"'||"FenceToken"||'"'"'|'"'"'||"Attempts"||'"'"'|'"'"'||coalesce("LastError",'"'"''"'"') FROM jobs WHERE "Id"=1;')
check "row unchanged after A woke up"                       "$row_after" "$row_before"
check "final status"                                        "$(sql 'SELECT "Status" FROM jobs WHERE "Id"=1;')" "Succeeded"
check "FenceToken (B's claim)"                              "$(sql 'SELECT "FenceToken" FROM jobs WHERE "Id"=1;')" "2"
check "B completed job 1"                                   "$(grep -c 'Successfully completed job 1' "$LOG_DIR/b.log" || true)" "1"
check "A completed job 1"                                   "$(grep -c 'Successfully completed job 1' "$LOG_DIR/a.log" || true)" "0"
a_rejected=$(grep -cE 'Lost fence token ownership for job 1|lease lost|Lost lease on job 1' "$LOG_DIR/a.log" || true)
check "A noticed it lost job 1 (fence or lease)"            "$( ((a_rejected > 0)) && echo yes || echo no)" "yes"
echo "        A's last words: $(grep -E 'job 1' "$LOG_DIR/a.log" | tail -n 2 | sed -E 's/^\S+ \S+ //' | tr '\n' ' ' | cut -c1-160)"

finish "(hung worker's late write rejected; row kept B's result)"
