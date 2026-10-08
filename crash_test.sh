#!/usr/bin/env bash
set -e

CONTAINER_ID="38a5f65dc93f"
API_URL="http://localhost:5200/api/jobs"
DB_CONN="Host=localhost;Port=5433;Database=jobrunner;Username=postgres;Password=postgres"

run_psql() {
    docker exec -i "$CONTAINER_ID" psql -U postgres -d jobrunner -t -c "$1"
}

run_psql_no_t() {
    docker exec -i "$CONTAINER_ID" psql -U postgres -d jobrunner -c "$1"
}

echo "=== 1. Cleaning database ==="
run_psql_no_t "TRUNCATE TABLE jobs RESTART IDENTITY CASCADE;"

echo "=== 2. Seeding 1 test job ==="
curl -s -X POST "$API_URL" \
    -H "Content-Type: application/json" \
    -d "{
      \"jobType\": \"SendEmail\",
      \"payload\": { \"to\": \"crash-test@example.com\" }
    }" > /dev/null

echo "=== 3. Launching a single worker and letting it claim the job ==="
ConnectionStrings__Default="$DB_CONN" dotnet run --project JobRunner.Worker &
WORKER_PID=$!

# Wait a couple seconds for the worker to claim and start running the job
sleep 3

echo "=== 4. Hard-killing the worker mid-execution (kill -9) ==="
kill -9 $WORKER_PID 2>/dev/null || true
echo "Worker $WORKER_PID killed abruptly."

# Verify the job is currently stuck in 'Running' state
STATUS_STUCK=$(run_psql "SELECT \"Status\" FROM jobs WHERE \"Id\" = 1;" | tr -d '[:space:]')
echo "Job status right after crash: $STATUS_STUCK (Expected: Running)"

echo "=== 5. Launching a recovery worker (will wait for stale timeout threshold) ==="
echo "Note: Stale timeout is configured to 30 seconds. Waiting for reclaim..."

# We start a new worker that will trigger ReclaimStaleAsync after the stale period
ConnectionStrings__Default="$DB_CONN" dotnet run --project JobRunner.Worker &
RECOVERY_PID=$!

# Wait up to 45 seconds for stale reclaim + execution completion
MAX_WAIT=45
ELAPSED=0
SUCCESS=0

while (( ELAPSED < MAX_WAIT )); do
    FINAL_STATUS=$(run_psql "SELECT \"Status\" FROM jobs WHERE \"Id\" = 1;" | tr -d '[:space:]')
    ATTEMPTS=$(run_psql "SELECT \"Attempts\" FROM jobs WHERE \"Id\" = 1;" | tr -d '[:space:]')
    
    if [[ "$FINAL_STATUS" == "Succeeded" ]]; then
        echo "✅ SUCCESS: Job recovered from crash and completed successfully! (Attempts: $ATTEMPTS)"
        SUCCESS=1
        break
    fi
    
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    echo "Waiting for recovery... Status: $FINAL_STATUS, Attempts: $ATTEMPTS (Elapsed: ${ELAPSED}s)"
end

# Clean up recovery worker
kill -SIGINT $RECOVERY_PID 2>/dev/null || true
wait $RECOVERY_PID 2>/dev/null || true

if [[ "$SUCCESS" -eq 1 ]]; then
    echo "🎉 CRASH RECOVERY TEST PASSED!"
    exit 0
else
    echo "💥 CRASH RECOVERY TEST FAILED: Job did not recover within timeout."
    exit 1
fi
