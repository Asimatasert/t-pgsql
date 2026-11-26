#!/usr/bin/env bash
# Regression: run lock follow-ups. (a) a stale take-over that loses a race to a plain acquirer
# retries instead of running unlocked and never removes a directory it does not own; (b) pid
# reuse is judged by the process start identity (Linux /proc field 22, elsewhere ps lstart with
# a tolerance; unparseable counts as live); (c) the host identity is the lower-cased short
# name; (d) batch --lock-wait / --no-lock reach the jobs; (e) the take-over mutex records its
# owner and is stolen only from a dead owner or after 60 s; (f) an all-skipped batch is not
# reported as a success. Hermetic: fakes only, background processes stopped by recorded PID.
#   bash tests/regress/lock-followups.sh   (T_PGSQL_BIN overrides ./t-pgsql)
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
ln -s "$BASH" "$BINDIR/bash"
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
{ printf '%s\n' "$@"; [ -t 0 ] || cat; } >> "$REC/curl.log"
printf '{"ok":true}\n'
exit 0
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BINDIR/$t"; done
chmod +x "$BINDIR"/*
export PATH="$BINDIR:$PATH" REC
export HOME="$TMP/home" T_PGSQL_FROM_PASSWORD=x T_PGSQL_STATE_DIR="$ST"
unset XDG_STATE_HOME
waitfile() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]; }
waitpid() { local i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$1" 2>/dev/null; }

# ---- the lock module of the binary under test, loaded for the unit checks -------------------
lock_src=$(awk '/^# RUN LOCK/ { f = 1; skip = 1; next }
    f && skip && /^# =+$/ { skip = 0; next }
    f && !skip && /^# =+$/ { exit }
    f && !skip { print }' "$BIN_SRC")
[ -n "$lock_src" ] || { echo "not ok - lock module found in the binary"; exit 1; }
log_warn() { :; }; log_info() { :; }; log_error() { :; }
trim() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
format_elapsed() { printf '%ss' "$1"; }
eval "$lock_src"
COMMAND=dump
SHORT=$(hostname -s 2>/dev/null || hostname); SHORT=$(printf '%s' "${SHORT%%.*}" | tr '[:upper:]' '[:lower:]')
if declare -F _lock_host_id >/dev/null; then _LOCK_HOST=$(_lock_host_id); else _LOCK_HOST=$(hostname); fi
LDIR="$TMP/locks"; mkdir -p "$LDIR"
sleep 60 & LIVE=$!; PIDS+=("$LIVE")
true & DEAD=$!; wait "$DEAD" 2>/dev/null
mkmeta() { # dir pid host start pstart
    mkdir -p "$1"
    printf 'pid=%s\nhost=%s\nstart=%s\npstart=%s\ncmd=dump\njob=\nkey=x\n' "$2" "$3" "$4" "$5" > "$1/meta"
}
now=$(date +%s)

# ---- (a) a competitor wins the mkdir between the rename and the taker's mkdir ----------------
D="$LDIR/race.lock"; rm -rf "$D"
mkmeta "$D" "$DEAD" "$SHORT" "$now" ""
_LOCK_HELD=()
rm() {   # test hook: right after the stale directory was renamed away, a plain acquirer wins
    if [ "$1" = -rf ] && [[ "$2" == *.old.* ]]; then
        command mkdir "$D" && printf 'pid=%s\nhost=%s\nstart=%s\npstart=\ncmd=dump\njob=\nkey=x\n' "$LIVE" "$SHORT" "$now" > "$D/meta"
    fi
    command rm "$@"
}
_lock_try "$D" x; rc=$?
unset -f rm
[ "$rc" -eq 3 ] && ok "(a) lost take-over race: try again (3), not 'run unlocked' (2)" || nok "(a) lost take-over race returned $rc"
[ "$(sed -n 's/^pid=//p' "$D/meta" 2>/dev/null)" = "$LIVE" ] && ok "(a) the competitor's lock directory is untouched" || nok "(a) competitor's lock was damaged"
[ "${#_LOCK_HELD[@]}" -eq 0 ] && ok "(a) the loser holds nothing" || nok "(a) loser holds ${#_LOCK_HELD[@]} lock(s)"
_lock_try "$D" x; rc=$?
[ "$rc" -eq 1 ] && ok "(a) the retry sees the live owner and reports it as held (1)" || nok "(a) retry returned $rc"
# competitor not yet through writing its meta: its directory must survive as well
D2="$LDIR/race2.lock"; rm -rf "$D2"; mkmeta "$D2" "$DEAD" "$SHORT" "$now" ""
rm() { if [ "$1" = -rf ] && [[ "$2" == *.old.* ]]; then command mkdir "$D2"; fi; command rm "$@"; }
_lock_try "$D2" x; rc=$?
unset -f rm
[ -d "$D2" ] && ok "(a) a directory created by someone else is never removed by the taker" || nok "(a) the taker removed a directory it does not own"
[ "$rc" -ne 2 ] && ok "(a) no 'run unlocked' result either (rc=$rc)" || nok "(a) returned 2 (run unlocked)"

# ---- (b) pid reuse ---------------------------------------------------------------------------
cur=$(_lock_pstart "$LIVE")
if [ -n "$cur" ]; then
    case "$cur" in proc:*|ps:*) ok "(b) start identity has a kind prefix: ${cur%%:*}" ;; *) nok "(b) start identity format: $cur" ;; esac
else
    nok "(b) no start identity for a live pid"
fi
_lock_pstart_same "$cur" "$cur"; r=$?; [ "$r" -eq 0 ] && ok "(b) the same identity is the same process" || nok "(b) same identity rc=$r"
case "$cur" in
    ps:*)
        e="${cur#ps:}"
        _lock_pstart_same "ps:$((e - 3600))" "$cur"; r=$?; [ "$r" -eq 1 ] && ok "(b) an hour apart: reused pid" || nok "(b) ps an hour apart rc=$r"
        _lock_pstart_same "ps:$((e + 2))" "$cur"; r=$?; [ "$r" -eq 0 ] && ok "(b) 2 s apart: same process (tolerance)" || nok "(b) ps 2 s apart rc=$r"
        ;;
    proc:*)
        _lock_pstart_same "proc:1" "$cur"; r=$?; [ "$r" -eq 1 ] && ok "(b) different start ticks: reused pid" || nok "(b) proc different rc=$r"
        ;;
esac
_lock_pstart_same "ps:abc" "$cur"; r=$?; [ "$r" -eq 0 ] && ok "(b) unparseable record counts as the same process" || nok "(b) unparseable rc=$r"
_lock_pstart_same "Thu Nov 26 10:00:00 2026" "$cur"; r=$?; [ "$r" -eq 0 ] && ok "(b) old text format counts as the same process" || nok "(b) old format rc=$r"
_lock_pstart_same "ps:100" ""; r=$?; [ "$r" -eq 0 ] && ok "(b) unknown current identity counts as the same process" || nok "(b) unknown current rc=$r"
D="$LDIR/reuse.lock"; rm -rf "$D"
mkmeta "$D" "$LIVE" "$SHORT" "$now" "garbage start text"
_lock_is_stale "$D"; r=$?; [ "$r" -eq 1 ] && ok "(b) a live owner with an unparseable start record is not stale" || nok "(b) garbage record made a live owner stale (rc=$r)"
case "$cur" in ps:*) old="ps:$(( ${cur#ps:} - 3600 ))" ;; *) old="proc:1" ;; esac
mkmeta "$D" "$LIVE" "$SHORT" "$now" "$old"
_lock_is_stale "$D"; r=$?; [ "$r" -eq 0 ] && ok "(b) a start identity that differs makes the lock stale (pid reused)" || nok "(b) reused pid not detected (rc=$r)"
mkmeta "$D" "$LIVE" "$SHORT" "$now" "$cur"
_lock_is_stale "$D"; r=$?; [ "$r" -eq 1 ] && ok "(b) the real owner's lock is not stale" || nok "(b) real owner's lock is stale (rc=$r)"

# ---- (c) host identity -----------------------------------------------------------------------
if declare -F _lock_host_id >/dev/null; then
    [ "$(_lock_host_id Foo.Example.Test)" = foo ] && ok "(c) host id is lower-cased and without domain" || nok "(c) host id: $(_lock_host_id Foo.Example.Test)"
fi
D="$LDIR/host.lock"; rm -rf "$D"
mkmeta "$D" "$DEAD" "${SHORT}.changed-domain.example.test" "$now" ""
_lock_is_stale "$D"; r=$?; [ "$r" -eq 0 ] && ok "(c) a changed domain suffix does not make a crashed run's lock foreign" || nok "(c) same host with another suffix is foreign (rc=$r)"
mkmeta "$D" "$DEAD" "$(printf '%s' "$SHORT" | tr '[:lower:]' '[:upper:]')" "$now" ""
_lock_is_stale "$D"; r=$?; [ "$r" -eq 0 ] && ok "(c) the host name case does not matter" || nok "(c) upper-case host differs (rc=$r)"
mkmeta "$D" "$DEAD" "another-host.example.test" "$now" ""
_lock_is_stale "$D"; r=$?; [ "$r" -eq 1 ] && ok "(c) another host's lock is still not taken over" || nok "(c) foreign host lock taken over (rc=$r)"

# ---- (e) the take-over mutex ------------------------------------------------------------------
minutes_ago() { # touch -t stamp for N minutes ago (GNU, then BSD date)
    date -d "$1 minutes ago" +%Y%m%d%H%M 2>/dev/null || date -v-"$1"M +%Y%m%d%H%M
}
MX="$LDIR/mx.lock.take"
rm -rf "$MX"; mkdir "$MX"; printf '%s\n' "$DEAD" > "$MX/owner"
if declare -F _lock_mx_acquire >/dev/null; then
    _lock_mx_acquire "$MX"; r=$?
    [ "$r" -eq 0 ] && [ "$(cat "$MX/owner" 2>/dev/null)" = "$$" ] && ok "(e) a mutex of a dead owner is stolen at once and records the new owner" || nok "(e) dead owner's mutex (rc=$r)"
    _lock_mx_release "$MX"; [ ! -e "$MX" ] && ok "(e) release removes the mutex" || nok "(e) mutex left behind"
    rm -rf "$MX"; mkdir "$MX"; printf '%s\n' "$LIVE" > "$MX/owner"
    _lock_mx_acquire "$MX"; r=$?
    [ "$r" -eq 1 ] && ok "(e) a fresh mutex of a live owner is respected" || nok "(e) live owner's fresh mutex taken (rc=$r)"
    touch -t "$(minutes_ago 3)" "$MX"
    _lock_mx_acquire "$MX"; r=$?
    [ "$r" -eq 0 ] && ok "(e) a mutex older than 60 s is stolen even from a live pid" || nok "(e) old mutex of a live pid kept (rc=$r)"
    rm -rf "$MX"; mkdir "$MX"
    _lock_mx_acquire "$MX"; r=$?
    [ "$r" -eq 1 ] && ok "(e) a fresh mutex without owner file is respected" || nok "(e) fresh ownerless mutex taken (rc=$r)"
    rm -rf "$MX"
else
    nok "(e) _lock_mx_acquire exists"
fi
# an orphaned mutex of a dead process no longer blocks a take-over for 60 s
D="$LDIR/orph.lock"; rm -rf "$D" "$D.take"
mkmeta "$D" "$DEAD" "$SHORT" "$now" ""
mkdir "$D.take"; printf '%s\n' "$DEAD" > "$D.take/owner"
_LOCK_HELD=(); _lock_try "$D" x; r=$?
[ "$r" -eq 0 ] && ok "(e) a stale lock is taken over despite an orphaned mutex" || nok "(e) orphaned mutex blocked the take-over (rc=$r)"
[ ! -e "$D.take" ] && ok "(e) the mutex is gone after the take-over" || nok "(e) mutex left after the take-over"

# ---- end-to-end helpers ----------------------------------------------------------------------
reset() { rm -rf "${REC:?}"/* "${OUT:?}" "${ST:?}"; mkdir -p "$OUT" "$REC"; }
DARGS=(dump --from postgres@localhost/appdb --output "$OUT" --compress none --no-meta --no-health-check --min-size-ratio 0)
startholder() { ( exec env PGD_SLEEP="$1" "$BASH" "$BIN" "${DARGS[@]}" >"$TMP/holder.out" 2>&1 </dev/null ) & H=$!; PIDS+=("$H"); waitfile "$REC/pg_dump.started" || nok "holder started"; }
endholder() { waitpid "$H" || { kill -TERM "$H" 2>/dev/null; waitpid "$H"; }; wait "$H" 2>/dev/null; }
mkjob() { printf '  %s:\n    command: dump\n    from: postgres@localhost/%s\n    password: x\n    output: %s\n    no_meta: true\n    no_health_check: true\n    compress: none\n    min_size_ratio: 0\n' "$1" "$2" "$OUT"; }
{ echo "jobs:"; mkjob job-a appdb; } > "$TMP/jobs.yaml"

# ---- (d) batch --no-lock and --lock-wait reach the jobs --------------------------------------
reset; startholder 25
out=$("$BASH" "$BIN" batch job-a --no-lock --yaml "$TMP/jobs.yaml" </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "(d) batch --no-lock runs the job while the target is held" || nok "(d) batch --no-lock (rc=$rc: $out)"
endholder
reset; startholder 25
out=$("$BASH" "$BIN" batch job-a --lock-wait 15 --yaml "$TMP/jobs.yaml" </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "(d) batch --lock-wait waits for the holder and then runs the job" || nok "(d) batch --lock-wait (rc=$rc: $out)"
endholder

# ---- (f) all jobs skipped: not a success -----------------------------------------------------
reset
{ echo "jobs:"; mkjob job-a appdb; mkjob job-b appdb; } > "$TMP/jobs2.yaml"
startholder 25
out=$("$BASH" "$BIN" batch all --yaml "$TMP/jobs2.yaml" --notify "telegram:121212:ALLSKIP:-100" --notify-summary </dev/null 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "(f) an all-skipped batch still exits 0" || nok "(f) all-skipped batch rc=$rc"
case "$out" in *"All jobs completed"*|*"jobs completed successfully"*) nok "(f) all-skipped batch is called a success: $out" ;; *) ok "(f) all-skipped batch is not called a success" ;; esac
case "$out" in *"were skipped"*) ok "(f) the summary says the jobs were skipped" ;; *) nok "(f) summary does not say skipped: $out" ;; esac
if grep -q 'Batch completed' "$REC/curl.log" 2>/dev/null; then nok "(f) a 'Batch completed' (success) notification was sent"; else ok "(f) no success notification for an all-skipped batch"; fi
grep -q 'Batch skipped' "$REC/curl.log" 2>/dev/null && ok "(f) a warning notification says the batch was skipped" || nok "(f) no skipped notification: $(cat "$REC/curl.log" 2>&1 | head -5)"
endholder

[ "$FAIL" -eq 0 ]
