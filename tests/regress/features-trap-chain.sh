#!/usr/bin/env bash
# Regression: heartbeat ping + run history + run lock together. All three hook into the
# program exit; ONE exit trap must run, in this order: history line, temp cleanup + lock
# release, final ping, whatever the exit path (ok, failed, TERM, lock-skipped). Hermetic:
# pg_dump, curl and friends are fakes; background runs are stopped by recorded PID.
#   bash tests/regress/features-trap-chain.sh   (T_PGSQL_BIN overrides ./t-pgsql)
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
# pg_dump: PGD_RC makes it fail; PGD_SLEEP (tenths of a second, bounded) makes it linger.
cat > "$BINDIR/pg_dump" <<'EOF'
#!/usr/bin/env bash
f=""
while [ $# -gt 0 ]; do [ "$1" = -f ] && f="$2"; shift; done
touch "$REC/pg_dump.started"
n=0; while [ "$n" -lt "${PGD_SLEEP:-0}" ] && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n + 1)); done
[ -n "${PGD_RC:-}" ] && exit "$PGD_RC"
{ printf 'PGDMP'; printf '%*s' 195 '' | tr ' ' x; } > "$f"
exit 0
EOF
# curl: append the URL of the stdin config (the ping target) to a log
cat > "$BINDIR/curl" <<'EOF'
#!/usr/bin/env bash
[ -t 0 ] || cat | sed -n 's/^url = "\(.*\)"$/\1/p' >> "$REC/pings.log"
exit 0
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$t"
done
chmod +x "$BINDIR"/*
export PATH="$BINDIR:$PATH" REC
export HOME="$TMP/home" T_PGSQL_FROM_PASSWORD=x T_PGSQL_STATE_DIR="$ST"
unset T_PGSQL_PING_DISABLE XDG_STATE_HOME

URL="https://hc.example.test/ping/CHAINSECRET"
HF="$ST/history.tsv"
reset() { rm -rf "${REC:?}"/* "${OUT:?}" "${ST:?}"; mkdir -p "$OUT" "$REC"; }
dargs() { printf '%s\n' dump --from postgres@localhost/appdb --output "$OUT" --compress none \
    --no-meta --no-health-check --min-size-ratio 0; }
run() { local -a a; mapfile -t a < <(dargs); out=$(env "$@" "$BASH" "$BIN" "${a[@]}" --ping "$URL" </dev/null 2>&1); rc=$?; }
pings() { cat "$REC/pings.log" 2>/dev/null; }
nlocks() { ls -d "$ST"/locks/*.lock 2>/dev/null | wc -l | tr -d ' '; }
hline() { awk -F'\t' -v s="$1" '$5 == s' "$HF" 2>/dev/null | tail -n 1; }
waitfile() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]; }
waitpid() { local i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$1" 2>/dev/null; }
bgrun() { # PGD_SLEEP [extra args]: background dump with the ping, PID in BGPID
    local sl="$1"; shift
    local -a a; mapfile -t a < <(dargs)
    ( exec env PGD_SLEEP="$sl" "$BASH" "$BIN" "${a[@]}" "$@" >"$TMP/bg.out" 2>&1 </dev/null ) &
    BGPID=$!; PIDS+=("$BGPID")
}

# 1. ok run
reset; run PGD_SLEEP=0
[ "$rc" -eq 0 ] && ok "ok run exits 0" || nok "ok run exits 0 (rc=$rc: $out)"
line=$(hline ok)
[ -n "$line" ] && [ "$(printf '%s' "$line" | awk -F'\t' '{print $3 "|" $4 "|" $6}')" = "dump|appdb|0" ] && ok "ok run: history line written next to --ping" || nok "ok run: history line written next to --ping: $(cat "$HF" 2>&1)"
[ "$(pings)" = "$URL/start
$URL" ] && ok "ok run: start + success pings" || nok "ok run: pings: $(pings)"
[ "$(nlocks)" -eq 0 ] && ok "ok run: lock released" || nok "ok run: lock released"

# 2. failed run (pg_dump exits 1)
reset; run PGD_RC=1
[ "$rc" -eq 1 ] && ok "failed run keeps exit status 1" || nok "failed run keeps exit status 1 (rc=$rc)"
line=$(hline failed)
[ -n "$line" ] && [ "$(printf '%s' "$line" | awk -F'\t' '{print $6}')" = 1 ] && ok "failed run: history line with exit 1" || nok "failed run: history line: $(cat "$HF" 2>&1)"
[ "$(pings)" = "$URL/start
$URL/fail" ] && ok "failed run: start + fail pings" || nok "failed run: pings: $(pings)"
[ "$(nlocks)" -eq 0 ] && ok "failed run: lock released" || nok "failed run: lock released"

# 3. TERM during the dump
reset
bgrun 30 --ping "$URL"; A=$BGPID
waitfile "$REC/pg_dump.started" || nok "TERM run started"
[ "$(nlocks)" -eq 1 ] && ok "TERM run: lock held while running" || nok "TERM run: lock held while running ($(nlocks))"
kill -TERM "$A"
waitpid "$A" || nok "TERM run ended"
wait "$A" 2>/dev/null; rc=$?
[ "$rc" -eq 143 ] && ok "TERM run exits 143" || nok "TERM run exits 143 (rc=$rc)"
line=$(hline failed)
[ -n "$line" ] && [ "$(printf '%s' "$line" | awk -F'\t' '{print $6}')" = 143 ] && ok "TERM run: history line with exit 143" || nok "TERM run: history line: $(cat "$HF" 2>&1)"
[ "$(pings)" = "$URL/start
$URL/fail" ] && ok "TERM run: start + fail pings" || nok "TERM run: pings: $(pings)"
[ "$(nlocks)" -eq 0 ] && ok "TERM run: lock released" || nok "TERM run: lock released"

# 4. lock-skipped run: no pings, the holder's lock is untouched, exit 75
reset
bgrun 20; H=$BGPID
waitfile "$REC/pg_dump.started" || nok "holder started"
run PGD_SLEEP=0
[ "$rc" -eq 75 ] && ok "lock-skipped run exits 75" || nok "lock-skipped run exits 75 (rc=$rc)"
[ -z "$(pings)" ] && ok "lock-skipped run: no ping at all" || nok "lock-skipped run: pings: $(pings)"
[ "$(nlocks)" -eq 1 ] && ok "lock-skipped run leaves the holder's lock alone" || nok "lock-skipped run leaves the holder's lock alone ($(nlocks))"
line=$(hline locked)
[ -n "$line" ] && [ "$(printf '%s' "$line" | awk -F'\t' '{print $6}')" = 75 ] && ok "lock-skipped run: history line with status locked, exit 75" || nok "lock-skipped run: history line: $(cat "$HF" 2>&1)"
waitpid "$H" || nok "holder ended"
wait "$H" 2>/dev/null
[ "$(nlocks)" -eq 0 ] && ok "holder released its lock" || nok "holder released its lock"

[ "$FAIL" -eq 0 ]
