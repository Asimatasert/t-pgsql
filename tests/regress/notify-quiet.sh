#!/usr/bin/env bash
# Regression: -q/--quiet must only reduce console output and success notifications.
# Failure notifications are still sent.
# Usage: bash tests/regress/notify-quiet.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/psql"
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

run() { # args = extra t-pgsql options; sets CALLS = number of curl invocations
    rm -f "$TMP"/rec/curl.*
    ( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$TMP/out" \
        --no-meta --no-health-check --notify "telegram:999000:QSECRET:-100" "$@" >"$TMP/run.out" 2>&1 </dev/null )
    RC=$?
    CALLS=$(ls "$TMP"/rec/curl.*.argv 2>/dev/null | wc -l | tr -d ' ')
}

PGDUMP_FAIL=1 run -q
[ "$RC" -ne 0 ] && ok "failing dump with -q exits non-zero" || nok "failing dump with -q exits non-zero"
[ "$CALLS" -ge 1 ] && ok "failure notification is sent under -q" || nok "failure notification is sent under -q"
grep -q "failed\|Failed" "$TMP"/rec/curl.1.argv 2>/dev/null && ok "the notification text reports the failure" || nok "the notification text reports the failure"

run -q
[ "$RC" -eq 0 ] && [ "$CALLS" -eq 0 ] && ok "success notification is still suppressed under -q" || nok "success notification is still suppressed under -q (calls=$CALLS)"

run
[ "$CALLS" -ge 1 ] && ok "success notification is sent without -q" || nok "success notification is sent without -q"

[ "$FAILS" -eq 0 ]
