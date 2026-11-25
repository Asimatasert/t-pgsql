#!/usr/bin/env bash
# Regression: scripts/run-tests.sh times out a hanging test, names it, shows
# output only for failing tests, prints a summary and fails the run.
# Works on a temp layout; the real tests are not run.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$(mktemp -d)"
HANG_PID=""
trap '[ -n "$HANG_PID" ] && kill "$HANG_PID" 2>/dev/null; rm -rf "$T"' EXIT

FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else nok "$d"; fi; }

if [ ! -f "$ROOT/scripts/run-tests.sh" ]; then
    nok "scripts/run-tests.sh exists"
    exit 1
fi
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    echo "ok - SKIP no timeout/gtimeout available"
    exit 0
fi

mkdir -p "$T/scripts" "$T/tests/regress"
cp "$ROOT/scripts/run-tests.sh" "$T/scripts/"
echo 'echo quiet-pass-output' > "$T/tests/regress/a-pass.sh"
printf 'echo loud-failure-output\nexit 3\n' > "$T/tests/regress/b-fail.sh"
# A test that starts a background sleeper, records its pid and then waits.
printf 'sleep 60 &\necho $! > "%s/hang.pid"\nwait\n' "$T" > "$T/tests/regress/c-hang.sh"

TEST_TIMEOUT=2 bash "$T/scripts/run-tests.sh" > "$T/out.txt" 2>&1
RC=$?
HANG_PID="$(cat "$T/hang.pid" 2>/dev/null || true)"

check "run fails when a test fails or hangs" test "$RC" -eq 1
check "hanging test is named as TIMEOUT" grep -q 'TIMEOUT: tests/regress/c-hang.sh' "$T/out.txt"
check "failing test is named with its exit code" grep -q 'FAIL: tests/regress/b-fail.sh (exit 3)' "$T/out.txt"
check "failing test output is printed" grep -q 'loud-failure-output' "$T/out.txt"
check "passing test output is not printed" bash -c "! grep -q quiet-pass-output '$T/out.txt'"
check "passing test is listed" grep -q 'PASS: tests/regress/a-pass.sh' "$T/out.txt"
check "summary line is printed" grep -q 'run-tests: 1 passed, 2 failed' "$T/out.txt"
sleep 1
check "the hanging test's background process was killed" \
    bash -c "[ -n '$HANG_PID' ] && ! kill -0 '$HANG_PID' 2>/dev/null"

# no tests at all passes
mkdir -p "$T/empty/scripts" "$T/empty/tests/regress"
cp "$ROOT/scripts/run-tests.sh" "$T/empty/scripts/"
check "no tests: run passes" bash "$T/empty/scripts/run-tests.sh"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS assertion(s) failed"; exit 1; fi
echo "all run-tests assertions passed"
