#!/usr/bin/env bash
# Regression: a run skipped by the run lock (exit 75) leaves a history line with status
# "locked" (not failed, not skipped); status shows it distinctly and --max-age does NOT count
# it as a fresh success; the skipped run sends no ping and no notification.
# Hermetic: pg_dump, curl and friends are fakes; the background holder is stopped by PID.
#   bash tests/regress/lock-history.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

BINDIR="$TMP/bin"; REC="$TMP/rec"; OUT="$TMP/out"; ST="$TMP/state"
mkdir -p "$BINDIR" "$REC" "$OUT" "$TMP/home"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$BINDIR/t-pgsql"; chmod +x "$BINDIR/t-pgsql"
BIN="$BINDIR/t-pgsql"
cat > "$BINDIR/pg_dump" <<'EOF'
#!/usr/bin/env bash
f=""
while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
touch "$REC/pg_dump.started"
n=0; while [ "$n" -lt "${PGD_SLEEP:-0}" ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
{ printf 'PGDMP'; printf '%*s' 195 '' | tr ' ' x; } > "$f"
exit 0
EOF
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
echo called >> "$REC/curl.log"
cat >/dev/null
exit 0
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$t"; done
chmod +x "$BINDIR"/*
export PATH="$BINDIR:$PATH" REC
export HOME="$TMP/home" T_PGSQL_FROM_PASSWORD=x T_PGSQL_STATE_DIR="$ST"
unset XDG_STATE_HOME NO_COLOR
HF="$ST/history.tsv"
waitfile() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]; }
waitpid() { local i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$1" 2>/dev/null; }
DARGS=(dump --from postgres@localhost/appdb --output "$OUT" --compress none --no-meta --no-health-check --min-size-ratio 0)

# holder: a dump that lingers (bounded) so the lock is held
( exec env PGD_SLEEP=25 "$BASH" "$BIN" "${DARGS[@]}" >"$TMP/holder.out" 2>&1 </dev/null ) &
H=$!; PIDS+=("$H")
waitfile "$REC/pg_dump.started" || nok "holder started"

out=$("$BASH" "$BIN" "${DARGS[@]}" --ping https://hc.example.test/p/LOCKSEC --notify "telegram:121212:LOCKSEC:-100" </dev/null 2>&1); rc=$?
[ "$rc" -eq 75 ] && ok "skipped run exits 75" || nok "skipped run exits 75 (rc=$rc)"
line=$(tail -n 1 "$HF" 2>/dev/null)
st=$(printf '%s' "$line" | awk -F'\t' '{print $5 "|" $6 "|" $3 "|" $4}')
[ "$st" = "locked|75|dump|appdb" ] && ok "history line: status locked, exit 75" || nok "history line: '$line'"
case "$line" in *failed*) nok "locked line is not 'failed'" ;; *) ok "locked line is not 'failed'" ;; esac
[ ! -e "$REC/curl.log" ] && ok "no ping and no notification from the locked run" || nok "locked run called curl"
out=$("$BASH" "$BIN" status --output "$OUT" </dev/null 2>&1)
case "$out" in *locked*) ok "status shows locked" ;; *) nok "status shows locked: $out" ;; esac
out=$("$BASH" "$BIN" status --json --output "$OUT" </dev/null 2>&1)
case "$out" in *'"result": "locked"'*) ok "status --json result is locked" ;; *) nok "status --json result: $out" ;; esac
kill -TERM "$H" 2>/dev/null; waitpid "$H" || nok "holder ended"; wait "$H" 2>/dev/null

# --max-age: a locked line is not a fresh success
now=$(date +%s)
rm -f "$HF"
hist() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" 2026-01-01T00:00:00Z dump appdb "$2" "$3" 1 100 "$4" >> "$HF"; }
hist $((now - 7200)) ok 0 ""
hist "$now" locked 75 "skipped: another run holds the lock"
"$BASH" "$BIN" status --max-age 1h --output "$OUT" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "--max-age: a locked line does not count as a fresh success" || nok "--max-age with old ok + fresh locked (rc=$rc)"
rm -f "$HF"
hist $((now - 60)) ok 0 ""
hist "$now" locked 75 "skipped: another run holds the lock"
"$BASH" "$BIN" status --max-age 1h --output "$OUT" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "--max-age: a recent ok before the locked line is still fresh" || nok "--max-age with fresh ok + locked (rc=$rc)"
rm -f "$HF"
hist $((now - 7200)) ok 0 ""
hist "$now" skipped 0 "recent dump exists"
"$BASH" "$BIN" status --max-age 1h --output "$OUT" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "--max-age: skipped (--skip-if-recent) still counts" || nok "--max-age with skipped (rc=$rc)"

[ "$FAIL" -eq 0 ]
