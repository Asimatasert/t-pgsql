#!/usr/bin/env bash
# Regression: "status" must not answer wrongly on bash 3.2 (mapfile is missing there and used to
# produce "No runs recorded yet." with exit 0 even with a populated history). It must either
# work or refuse with exit 2; and the status code must use no bash-4-only builtin.
# Hermetic: only the history file is read.
#   bash tests/regress/status-bash3.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

ST="$TMP/state"; OUT="$TMP/out"; mkdir -p "$ST" "$OUT" "$TMP/home"
export HOME="$TMP/home" T_PGSQL_STATE_DIR="$ST"
unset XDG_STATE_HOME
now=$(date +%s)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" 2026-01-01T00:00:00Z dump appdb ok 0 3 100 "" > "$ST/history.tsv"
chmod 600 "$ST/history.tsv"

# 1. the source of the status code path has no bash-4-only builtin
n=$(grep -c 'mapfile\|readarray\|declare -A\|local -A' "$ROOT/src/74-status.sh")
[ "$n" -eq 0 ] && ok "74-status.sh uses no mapfile/readarray/associative arrays" || nok "74-status.sh uses $n bash-4-only constructs"

# 2. bash 5 (or any 4+): the recorded run is shown
out=$("$BASH" "$BIN" status --output "$OUT" 2>&1 </dev/null); rc=$?
case "$out" in *appdb*) ok "status shows the recorded run" ;; *) nok "status shows the recorded run: $out" ;; esac

# 3. an old bash: a clear error and exit 2, never "No runs recorded yet."
OLD=""
for b in /bin/bash /usr/bin/bash; do
    if [ -x "$b" ] && [ "$("$b" -c 'echo ${BASH_VERSINFO[0]}')" -lt 4 ]; then OLD="$b"; break; fi
done
if [ -n "$OLD" ]; then
    sed '1s|.*|#!/usr/bin/env bash|' "$BIN" > "$TMP/t-pgsql"
    out=$("$OLD" "$TMP/t-pgsql" status --output "$OUT" 2>&1 </dev/null); rc=$?
    case "$out" in *"No runs recorded"*) nok "old bash prints a wrong answer: $out" ;; *) ok "old bash does not claim 'No runs recorded yet.'" ;; esac
    [ "$rc" -eq 2 ] && ok "old bash: exit 2" || nok "old bash: exit 2 (rc=$rc: $out)"
    case "$out" in *"bash 4"*) ok "old bash: clear message" ;; *) nok "old bash: clear message: $out" ;; esac
    out=$("$OLD" "$TMP/t-pgsql" status --max-age 1h --output "$OUT" 2>&1 </dev/null); rc=$?
    [ "$rc" -eq 2 ] && ok "old bash with --max-age: exit 2, not 3" || nok "old bash with --max-age: exit 2 (rc=$rc)"
else
    echo "ok - (skipped: no bash older than 4 on this machine)"
fi

[ "$FAIL" -eq 0 ]
