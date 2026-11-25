#!/usr/bin/env bash
# Regression: failures that used to exit silently (--health-check-fail, missing --from, bad
# connection string) must reach the configured notification channel, exactly once.
# Usage: bash tests/regress/notify-early-failure.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAILS=0
ok() { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAILS=$((FAILS + 1)); }

mkdir -p "$TMP/bin" "$TMP/rec"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$TMP/bin/t-pgsql"; chmod +x "$TMP/bin/t-pgsql"
ln -s "$BASH" "$TMP/bin/bash"
# Fake psql fails (source unreachable) when PSQL_FAIL=1.
printf '#!/bin/sh\n[ "$PSQL_FAIL" = 1 ] && exit 2\nexit 0\n' > "$TMP/bin/psql"
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
[ "$PGDUMP_FAIL" = 1 ] && exit 1
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'fake dump\n' >> "$f"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"

run() { # args = t-pgsql arguments; sets RC and CALLS
    rm -f "$TMP"/rec/curl.*
    ( cd "$TMP" && t-pgsql "$@" --notify "telegram:121212:EFSECRET:-100" >"$TMP/run.out" 2>&1 </dev/null )
    RC=$?
    CALLS=$(ls "$TMP"/rec/curl.*.argv 2>/dev/null | wc -l | tr -d ' ')
}
sent_failure() { cat "$TMP"/rec/curl.*.argv 2>/dev/null | grep -q "❌"; }

# 1. --health-check-fail: source unreachable
PSQL_FAIL=1 run dump --from postgres@localhost/appdb --password x --output "$TMP/out" --no-meta --health-check-fail
[ "$RC" -ne 0 ] && ok "--health-check-fail still exits non-zero" || nok "--health-check-fail still exits non-zero"
sent_failure && ok "--health-check-fail sends a failure notification" || nok "--health-check-fail sends a failure notification"

# 2. missing --from
run dump --password x --output "$TMP/out" --no-meta
[ "$RC" -ne 0 ] && ok "missing --from still exits non-zero" || nok "missing --from still exits non-zero"
sent_failure && ok "missing --from sends a failure notification" || nok "missing --from sends a failure notification"

# 3. unparseable source connection string
run dump --from "ssh://" --password x --output "$TMP/out" --no-meta
if [ "$RC" -ne 0 ]; then
    sent_failure && ok "an invalid source connection sends a failure notification" || nok "an invalid source connection sends a failure notification"
else
    nok "an invalid source connection exits non-zero"
fi

# 4. a normal pg_dump failure is announced exactly once (no duplicate from the catch-all)
PGDUMP_FAIL=1 run dump --from postgres@localhost/appdb --password x --output "$TMP/out" --no-meta --no-health-check
[ "$CALLS" -eq 1 ] && ok "a failing dump produces exactly one notification" || nok "a failing dump produces exactly one notification (calls=$CALLS)"

# 5. success is not reported as a failure
run dump --from postgres@localhost/appdb --password x --output "$TMP/out" --no-meta --no-health-check
[ "$RC" -eq 0 ] && ! sent_failure && ok "a successful dump sends no failure notification" || nok "a successful dump sends no failure notification"

# 6. secrets stay off argv here too
if cat "$TMP"/rec/curl.*.argv 2>/dev/null | grep -q "EFSECRET"; then nok "token not on curl argv"; else ok "token not on curl argv"; fi

[ "$FAILS" -eq 0 ]
