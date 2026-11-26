#!/usr/bin/env bash
# Regression: no colour escape codes when stdout is not a terminal or NO_COLOR is set, and
# never in log files or notification text.
# Usage: bash tests/regress/cli-no-color.sh   (T_PGSQL_BIN=/path/to/t-pgsql for another build)
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
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
printf 'PGDMP\nfake dump\n' >> "$f"
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
chmod +x "$TMP/bin/psql" "$TMP/bin/pg_dump" "$TMP/bin/curl"
. "$ROOT/tests/regress/lib/fakes.sh"; fake_pg_tools "$TMP/bin"
export PATH="$TMP/bin:$PATH" REC="$TMP/rec"
ESC="$(printf '\033')"
no_esc() { ! grep -q "$ESC" "$@"; }

# 1. stdout and stderr redirected to a file: no escape codes
( cd "$TMP" && t-pgsql jobs list --yaml "$TMP/missing.yaml" >"$TMP/list.out" 2>&1 </dev/null )
grep -q "WARN" "$TMP/list.out" && ok "the warning is still printed" || nok "the warning is still printed"
no_esc "$TMP/list.out" && ok "no escape codes when output is not a terminal" || nok "no escape codes when output is not a terminal"

# 2. NO_COLOR set
( cd "$TMP" && NO_COLOR=1 t-pgsql jobs list --yaml "$TMP/missing.yaml" >"$TMP/list2.out" 2>&1 </dev/null )
no_esc "$TMP/list2.out" && ok "no escape codes with NO_COLOR set" || nok "no escape codes with NO_COLOR set"

# 3. a dump name that itself carries an escape sequence must not reach the log file or the notification
( cd "$TMP" && t-pgsql dump --from postgres@localhost/appdb --password x --output "$TMP/out" \
    --no-meta --no-health-check --dump-name "${ESC}[31mred${ESC}[0m" --log "$TMP/run.log" \
    --notify "telegram:717171:COLSECRET:-100" >"$TMP/dump.out" 2>&1 </dev/null )
grep -q "red" "$TMP/run.log" && ok "log file is written" || nok "log file is written"
no_esc "$TMP/run.log" && ok "log file contains no escape codes" || nok "log file contains no escape codes"
cat "$TMP"/rec/curl.*.argv > "$TMP/argv.all" 2>/dev/null
grep -q "red" "$TMP/argv.all" && ok "notification was sent" || nok "notification was sent"
no_esc "$TMP/argv.all" && ok "notification text contains no escape codes" || nok "notification text contains no escape codes"

[ "$FAILS" -eq 0 ]
