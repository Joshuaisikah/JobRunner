#!/usr/bin/env bash
set -e

CONTAINER_ID="38a5f65dc93f"
API_URL="http://localhost:5200/api/jobs"
TOTAL_JOBS=200
DB_CONN="Host=localhost;Port=5433;Database=jobrunner;Username=postgres;Password=postgres"

run_psql() {
    docker exec -i "$CONTAINER_ID" psql -U postgres -d jobrunner -t -c "$1"
}

run_psql_no_t() {
    docker exec -i "$CONTAINER_ID" psql -U postgres -d jobrunner -c "$1"
}

echo "=== 1. Cleaning up any old jobs from database ==="
run_psql_no_t "TRUNCATE TABLE jobs RESTART IDENTITY CASCADE;"

echo "=== 2. Seeding $TOTAL_JOBS jobs via API ==="
for ((i=1; i<=TOTAL_JOBS; i++)); do
    curl -s -X POST "$API_URL" \
        -H "Content-Type: application/json" \
        -d "{
          \"jobType\": \"SendEmail\",
          \"payload\": {
            \"to\": \"user$i@example.com\"
          }
        }" > /dev/null
done
echo "Seeding complete."

echo "=== 3. Launching 3 workers concurrently ==="
ConnectionStrings__Default="$DB_CONN" dotnet run --project JobRunner.Worker &
W1=$!
ConnectionStrings__Default="$DB_CONN" dotnet run --project JobRunner.Worker &
W2=$!
ConnectionStrings__Default="$DB_CONN" dotnet run --project JobRunner.Worker &
W3=$!

echo "Workers started (PIDs: $W1, $W2, $W3). Waiting for jobs to process..."

MAX_WAIT=90
ELAPSED=0
while (( ELAPSED < MAX_WAIT )); do
    PENDING_COUNT=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" IN ('Pending', 'Running');" | tr -d '[:space:]')
    
    if [[ "$PENDING_COUNT" -eq 0 ]]; then
        echo "All jobs processed!"
        kill $W1 $W2 $W3 2>/dev/null || true
        wait $W1 $W2 $W3 2>/dev/null || true
        break
    fi
    
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo "Waiting... Remaining pending/running jobs: $PENDING_COUNT (Elapsed: ${ELAPSED}s)"
done

echo "=== 4. Stopping workers gracefully ==="
kill -SIGINT $W1 $W2 $W3 2>/dev/null || true
wait $W1 $W2 $W3 2>/dev/null || true

echo "=== 5. Asserting Results ==="

PENDING_FINAL=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" NOT IN ('Succeeded', 'Failed');" | tr -d '[:space:]')
SUCCEEDED_COUNT=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" = 'Succeeded';" | tr -d '[:space:]')
FAILED_COUNT=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Status\" = 'Failed';" | tr -d '[:space:]')
MULTIPLE_ATTEMPTS=$(run_psql "SELECT COUNT(*) FROM jobs WHERE \"Attempts\" <> 1;" | tr -d '[:space:]')

echo "-----------------------------------"
echo "Total Jobs:       $TOTAL_JOBS"
echo "Succeeded:        $SUCCEEDED_COUNT"
echo "Failed:           $FAILED_COUNT"
echo "Unfinished:       $PENDING_FINAL"
echo "Attempts <> 1:    $MULTIPLE_ATTEMPTS"
echo "-----------------------------------"

FAILED_TEST=0

if [[ "$PENDING_FINAL" -ne 0 ]]; then
    echo "❌ ERROR: $PENDING_FINAL jobs are still stuck in an active/non-terminal state!"
    FAILED_TEST=1
fi

if [[ "$SUCCEEDED_COUNT" -ne "$TOTAL_JOBS" ]]; then
    echo "❌ ERROR: Expected $TOTAL_JOBS succeeded jobs, but found $SUCCEEDED_COUNT (Failed: $FAILED_COUNT)."
    FAILED_TEST=1
else
    echo "✅ SUCCESS: All 200 jobs succeeded!"
fi

if [[ "$MULTIPLE_ATTEMPTS" -ne 0 ]]; then
    echo "❌ ERROR: Found $MULTIPLE_ATTEMPTS jobs with Attempts <> 1! Concurrency safety violated."
    FAILED_TEST=1
else
    echo "✅ SUCCESS: All jobs processed with exactly 1 attempt (zero duplicate claims)."
fi

if [[ "$FAILED_TEST" -eq 0 ]]; then
    echo "🎉 CONCURRENCY TEST PASSED CLEANLY!"
    exit 0
else
    echo "💥 CONCURRENCY TEST FAILED."
    exit 1
fi
