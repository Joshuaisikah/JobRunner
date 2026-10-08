#!/usr/bin/env bash
# Runs every acceptance test once and prints the PROJECTS.md checklist.
# Criterion 2 (20 consecutive passes) is separate because it takes ~30 min:
#     ./concurrency_loop.sh 20
set -uo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="test-results/acceptance-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

run() { # run <criterion text> <script>
    local name; name=$(basename "$2" .sh)
    "$2" >"$OUT_DIR/$name.log" 2>&1
    local code=$?
    local mark="❌"; [[ $code -eq 0 ]] && mark="✅"; [[ $code -eq 2 ]] && mark="⚠️ "
    printf '%s  %-62s %s\n' "$mark" "$1" "$(grep -hE 'RESULT:|ENVIRONMENT:' "$OUT_DIR/$name.log" | tail -n 1 | sed -E 's/^\[[0-9:]+\] //' | cut -c1-90)"
}

run "1. 3 workers, 200 jobs -> each executed exactly once"   ./concurrency_test.sh
echo "    2. 20 consecutive passes -> run ./concurrency_loop.sh 20"
run "3. kill -9 mid-job -> re-run after stale timeout"        ./crash_test.sh
run "4. hung worker cannot write its result afterwards"       ./tests/hang_test.sh
run "5. job 60s ahead not claimed at t+10s"                   ./tests/schedule_test.sh
run "6. claim query uses the intended index (EXPLAIN)"        ./tests/explain_test.sh
run "7. nothing stuck in Running forever (DB outage)"         ./tests/outage_test.sh
echo
echo "full logs: $OUT_DIR"
