#!/usr/bin/env bash
#
# run-tests.sh — run every tests/regress/*.sh (and tests/run.sh when present)
# with a per-test time limit. Used by CI and by the release gate.
#
#   TEST_TIMEOUT=180   seconds per test (default 180)
#
# A test that exceeds the limit is killed, reported by name and fails the run.
# Output of a test is printed only when it fails. Passes when there are no tests.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LIMIT="${TEST_TIMEOUT:-180}"
TMO=""
if command -v timeout >/dev/null 2>&1; then
    TMO="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TMO="gtimeout"
else
    echo "run-tests: no timeout/gtimeout found; tests run WITHOUT a time limit" >&2
fi

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

pass=0
fail=0
failed=""

run_one() {
    local t="$1" rc
    if [ -n "$TMO" ]; then
        "$TMO" -k 10 "$LIMIT" bash "$t" > "$LOG" 2>&1
    else
        bash "$t" > "$LOG" 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1))
        echo "PASS: $t"
        return
    fi
    fail=$((fail + 1))
    failed="$failed $t"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        echo "TIMEOUT: $t (killed after ${LIMIT}s)"
    else
        echo "FAIL: $t (exit $rc)"
    fi
    echo "----- output of $t -----"
    cat "$LOG"
    echo "----- end of $t -----"
}

for t in tests/regress/*.sh; do
    [ -e "$t" ] || continue
    run_one "$t"
done
if [ -f tests/run.sh ]; then
    run_one tests/run.sh
fi

echo "run-tests: $pass passed, $fail failed"
if [ "$fail" -ne 0 ]; then
    echo "run-tests: failed:$failed"
    exit 1
fi
exit 0
