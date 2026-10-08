#!/usr/bin/env bash
# Criterion 6: the claim query uses the intended index (proved with EXPLAIN).
#
# Seeds 50k rows (10% Pending) so the planner has a real choice, ANALYZEs, then EXPLAINs the
# claim and stale-reclaim subqueries. Passing means: an Index Scan on the partial index and
# no Sort node (the index order already satisfies ORDER BY) and no Seq Scan.
#
# NOTE: the SQL below mirrors JobStore.ClaimAsync / ReclaimStaleAsync. If you change those
# queries, change these too, or this test proves something about a query you no longer run.
source "$(dirname "$0")/lib.sh"
preconditions --no-api

log "=== 1. Seeding 50,000 rows and ANALYZE ==="
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null
sql "INSERT INTO jobs (\"JobType\",\"Payload\",\"Status\",\"Attempts\",\"RunAt\",\"CreatedAt\",\"FenceToken\",\"ClaimedAt\")
     SELECT 'SendEmail','{}',
            CASE WHEN g % 10 = 0 THEN 'Pending' WHEN g % 10 = 1 THEN 'Running' ELSE 'Succeeded' END,
            1, now() - (g || ' seconds')::interval, now(), 1, now() - (g || ' seconds')::interval
     FROM generate_series(1, 50000) g;" >/dev/null
sql 'ANALYZE jobs;' >/dev/null

claim_plan=$(sql "EXPLAIN SELECT \"Id\" FROM jobs
                  WHERE \"Status\" = 'Pending' AND \"RunAt\" <= now()
                  ORDER BY \"RunAt\", \"Id\" LIMIT 10 FOR UPDATE SKIP LOCKED;")
stale_plan=$(sql "EXPLAIN SELECT \"Id\" FROM jobs
                  WHERE \"Status\" = 'Running' AND \"ClaimedAt\" <= now() - interval '30 seconds'
                    AND \"Attempts\" < \"MaxAttempts\"
                  ORDER BY \"ClaimedAt\", \"Id\" LIMIT 10 FOR UPDATE SKIP LOCKED;")
sql 'TRUNCATE TABLE jobs RESTART IDENTITY;' >/dev/null

echo "--- claim plan:";  echo "$claim_plan"
echo "--- stale plan:";  echo "$stale_plan"

log "=== 2. Assertions ==="
has() { grep -qE "$2" <<<"$1" && echo yes || echo no; }
check "claim: Index Scan using IX_jobs_claim"     "$(has "$claim_plan" 'Index Scan using "IX_jobs_claim"')" "yes"
check "claim: no Sort node"                       "$(has "$claim_plan" '(^|[^a-zA-Z])Sort')" "no"
check "claim: no Seq Scan"                        "$(has "$claim_plan" 'Seq Scan')" "no"
check "stale: Index Scan using IX_jobs_stale"     "$(has "$stale_plan" 'Index Scan using "IX_jobs_stale"')" "yes"
check "stale: no Sort node"                       "$(has "$stale_plan" '(^|[^a-zA-Z])Sort')" "no"
check "stale: no Seq Scan"                        "$(has "$stale_plan" 'Seq Scan')" "no"

finish "(both claim queries are served in index order)"
