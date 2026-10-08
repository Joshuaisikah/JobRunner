#!/usr/bin/env bash
set -e

API_URL="http://localhost:5200/api/jobs"
TOTAL_JOBS=200

# Dynamically find the postgres container ID by image name
get_container_id() {
    docker ps -q -f ancestor=postgres | head -n 1
}

run_psql() {
    local cid=$(get_container_id)
    docker exec -i "$cid" psql -U postgres -d jobrunner -t -c "$1"
}

run_psql_no_t() {
    local cid=$(get_container_id)
    docker exec -i "$cid" psql -U postgres -d jobrunner -c "$1"
}

echo "=== 1. Cleaning up any old jobs from database ==="
run_psql_no_t "TRUNCATE TABLE jobs RESTART IDENTITY CASCADE;"

echo "=== 2. Seeding $TOTAL_JOBS jobs via API ==="
for ((i=1; i<=TOTAL_JOBS; i++)); do
    curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{\"jobType\": \"SendEmail\", \"payload\": \"{\\\"to\\\": \\\"user$i@example.com\\\"}\"}" > /dev/null
    
    if (( i % 50 == 0 )); then
        echo "Seeded $i jobs..."
    fi
done
echo "Seeding complete."

echo "=== 3. Launching 3 workers concurrently ==="
dotnet run --project JobRunner.Worker &
W1=$!
dotnet run --project JobRunner.Worker &
W2=$!
dotnet run --project JobRunner.Worker &
W3=$!

echo "Workers started (PIDs: $W1, $W2, $W3). Waiting for jobs to process..."

MAX_WAIT=60
ELAPSED=0
while (( ELAPSED < MAX_WAIT )); do
    PENDING_COUNT=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" IN ('Pending', 'Running');" | tr -d '[:space:]')
    
    if [[ "$PENDING_COUNT" -eq 0 ]]; then
        echo "All jobs processed!"
        break
    fi
    
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    echo "Waiting... Remaining pending/running jobs: $PENDING_COUNT (Elapsed: ${ELAPSED}s)"
done

echo "=== 4. Stopping workers ==="
kill $W1 $W2 $W3 2>/dev/null || true
wait $W1 $W2 $W3 2>/dev/null || true

echo "=== 5. Asserting Results ==="

PENDING_FINAL=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" NOT IN ('Succeeded', 'Failed');" | tr -d '[:space:]')
SUCCEEDED_COUNT=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" = 'Succeeded';" | tr -d '[:space:]')
FAILED_COUNT=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" = 'Failed';" | tr -d '[:space:]')

echo "-----------------------------------"
echo "Total Jobs: $TOTAL_JOBS"
echo "Succeeded:  $SUCCEEDED_COUNT"
echo "Failed:     $FAILED_COUNT"
echo "Unfinished: $PENDING_FINAL"
echo "-----------------------------------"

FAILED_TEST=0

if [[ "$PENDING_FINAL" -ne 0 ]]; then
    echo "❌ ERROR: $PENDING_FINAL jobs are still stuck in an active/non-terminal state!"
    FAILED_TEST=1
fi

TOTAL_DONE=$((SUCCEEDED_COUNT + FAILED_COUNT))
if [[ "$TOTAL_DONE" -ne "$TOTAL_JOBS" ]]; then
    echo "❌ ERROR: Expected $TOTAL_JOBS completed jobs, but found $TOTAL_DONE."
    FAILED_TEST=1
else
    echo "✅ SUCCESS: Every job reached a terminal state."
fi

if [[ "$FAILED_TEST" -eq 0 ]]; then
    echo "🎉 CONCURRENCY TEST PASSED CLEANLY!"
    exit 0
else
    echo "💥 CONCURRENCY TEST FAILED."
    exit 1
fi
