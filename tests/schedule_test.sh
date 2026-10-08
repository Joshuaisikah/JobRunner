#!/usr/bin/env bash
# Criterion 5: a job scheduled 60s ahead is not claimed at t+10s.
#
# Also checks the other half, so a broken claim query can't pass by claiming nothing:
# the job IS picked up once runAt arrives, and it was claimed no earlier than runAt.
source "$(dirname "$0")/lib.sh"

AHEAD=60
preconditions

log "=== 1. Seed one job with runAt = now + ${AHEAD}s ==="
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null
run_at=$(date -u -d "+${AHEAD} sec" +%Y-%m-%dT%H:%M:%SZ)
seeded_at=$SECONDS
code=$(post_job "{\"jobType\":\"SendEmail\",\"payload\":{\"to\":\"a@x\",\"subject\":\"s\",\"body\":\"b\"},\"runAt\":\"$run_at\"}")
[[ "$code" == "201" ]] || env_fail "seeding returned HTTP $code"
log "runAt = $run_at"

log "=== 2. Start 3 workers (more chances to claim early) ==="
start_worker w1; start_worker w2; start_worker w3

status_at() { # status_at <t>: sleep until t seconds after seeding, then report status|attempts
    local wait=$(($1 - (SECONDS - seeded_at)))
    ((wait > 0)) && sleep "$wait"
    sql 'SELECT "Status"||'"'"'|'"'"'||"Attempts" FROM jobs WHERE "Id"=1;'
}
at10=$(status_at 10)
at50=$(status_at 50)
log "t+10: $at10   t+50: $at50"

log "=== 3. Waiting for it to run after runAt ==="
until [[ "$(sql 'SELECT "Status" FROM jobs WHERE "Id"=1;')" == "Succeeded" ]]; do
    ((SECONDS - seeded_at < AHEAD + 30)) || break
    sleep 1
done

log "=== 4. Assertions ==="
check "t+10: still Pending, never claimed"                  "$at10" "Pending|0"
check "t+50: still Pending, never claimed"                  "$at50" "Pending|0"
check "eventually Succeeded"                                "$(sql 'SELECT "Status" FROM jobs WHERE "Id"=1;')" "Succeeded"
check "claimed no earlier than runAt"                       "$(sql 'SELECT ("ClaimedAt" >= "RunAt")::text FROM jobs WHERE "Id"=1;')" "true"
check "executed exactly once"                               "$(cat "$LOG_DIR"/w*.log | grep -c 'Executing job 1 ' || true)" "1"

finish "(not claimed before runAt, run once after it)"
