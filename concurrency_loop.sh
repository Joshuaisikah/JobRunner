#!/usr/bin/env bash
# Acceptance criterion 2: run concurrency_test.sh N times (default 20), N passes required.
# Every run's full output is kept under the results directory printed at the end.
#
# Usage:   ./concurrency_loop.sh [runs]

set -uo pipefail
cd "$(dirname "$0")"

RUNS="${1:-20}"
OUT_DIR="test-results/concurrency-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT_DIR"

pass=0 fail=0 env=0
for ((r = 1; r <= RUNS; r++)); do
    KEEP_LOGS=0 ./concurrency_test.sh >"$OUT_DIR/run-$r.log" 2>&1
    code=$?
    summary=$(grep 'RESULT:\|ENVIRONMENT:\|FAIL:' "$OUT_DIR/run-$r.log" | tail -n 1 | sed 's/^\[[0-9:]*\] //')
    case $code in
        0) pass=$((pass + 1)) ;;
        2) env=$((env + 1)) ;;
        *) fail=$((fail + 1)) ;;
    esac
    printf 'run %2d/%d  exit=%d  %s\n' "$r" "$RUNS" "$code" "$summary"
    # An environment failure (e.g. DB down) will repeat; stop rather than burn 20 runs.
    [[ $code -eq 2 ]] && break
done

echo
echo "passed $pass / $RUNS   failed $fail   environment errors $env"
echo "full logs: $OUT_DIR"
[[ $pass -eq $RUNS ]]
