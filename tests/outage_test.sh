#!/usr/bin/env bash
# Criterion 7: nothing is ever stuck in Running forever, even across a database outage.
#
#   1. Two workers claim batches of 10 and start executing.
#   2. The database is stopped for OUTAGE seconds, mid-batch, then started again.
#      Writes that were in flight fail; batches get abandoned part-way.
#   3. Within StaleTimeout + 2 x ReclaimInterval + slack after the DB is back, every job must
#      be terminal. A job that is Running with a fresh ClaimedAt but never finishing is held
#      by someone who will never run it: that is "stuck forever", and it fails the test.
source "$(dirname "$0")/lib.sh"

OUTAGE="${OUTAGE:-4}"
JOBS=20
STALE=$(worker_const StaleTimeout)
RECLAIM=$(worker_const ReclaimInterval)
preconditions --no-api

log "=== 1. Seed $JOBS jobs; start 2 workers ==="
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null
sql "INSERT INTO jobs (\"JobType\",\"Payload\",\"Status\",\"Attempts\",\"RunAt\",\"CreatedAt\",\"FenceToken\")
     SELECT 'SendEmail','{\"to\":\"x\",\"subject\":\"s\",\"body\":\"b\"}','Pending',0,now(),now(),0
     FROM generate_series(1, $JOBS);" >/dev/null
start_worker w1; start_worker w2
# Wait until both workers are mid-batch (each has executed at least 2 jobs).
for w in w1 w2; do
    deadline=$((SECONDS + 30))
    until [[ $(grep -c 'Executing job' "$LOG_DIR/$w.log" 2>/dev/null || true) -ge 2 ]]; do
        ((SECONDS < deadline)) || env_fail "$w never got going"
        sleep 0.05
    done
done

log "=== 2. Database outage: ${OUTAGE}s ==="
docker stop -t 0 "$DB_CONTAINER" >/dev/null
sleep "$OUTAGE"
docker start "$DB_CONTAINER" >/dev/null
until db_up; do sleep 0.2; done
back=$SECONDS
log "Database back"

deadline_secs=$((STALE + 2 * RECLAIM + 20))
log "=== 3. Every job must be terminal within ${deadline_secs}s ==="
while :; do
    open=$(sql "SELECT count(*) FROM jobs WHERE \"Status\" IN ('Pending','Running');")
    [[ "$open" -eq 0 ]] && break
    if ((SECONDS - back > deadline_secs)); then
        log "Deadline passed with $open job(s) still open:"
        sql "SELECT '  job '||\"Id\"||' '||\"Status\"||' attempts='||\"Attempts\"||' ClaimedAt '||
                    coalesce(round(extract(epoch FROM now()-\"ClaimedAt\"))::text,'-')||'s ago'
             FROM jobs WHERE \"Status\" IN ('Pending','Running') ORDER BY \"Id\";"
        break
    fi
    # A worker that fail-fast exits is allowed; but recovery needs someone, so replace it.
    for w in w1 w2; do
        if ! kill -0 "${WORKER_PID[$w]}" 2>/dev/null; then
            log "$w exited (fail-fast?) -> starting a replacement"
            mv "$LOG_DIR/$w.log" "$LOG_DIR/$w.exited.$SECONDS.log"; start_worker "$w"
        fi
    done
    sleep 2
done
recovered_in=$((SECONDS - back))
for w in w1 w2; do stop_worker "$w"; done

log "=== 4. Assertions ==="
check "jobs still Pending/Running"                 "$(sql "SELECT count(*) FROM jobs WHERE \"Status\" IN ('Pending','Running');")" "0"
check "jobs Succeeded"                             "$(sql "SELECT count(*) FROM jobs WHERE \"Status\"='Succeeded';")" "$JOBS"
echo "        main-loop errors during outage: $(cat "$LOG_DIR"/w*.log | grep -c 'Error occurred in worker main loop' || true)," \
     "heartbeat misses: $(cat "$LOG_DIR"/w*.log | grep -c 'Heartbeat failed' || true)," \
     "reclaims: $(cat "$LOG_DIR"/w*.log | grep -c 'Reclaimed stale job' || true)"

finish "(${OUTAGE}s outage; watched ${recovered_in}s after the DB came back)"
