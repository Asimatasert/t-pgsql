#!/usr/bin/env bash
# Regression: run lock. Two runs that write the same target must not overlap: the second
# one skips (exit 75, no failure notification) or waits (--lock-wait); runs that write
# different targets are independent; stale locks (dead owner, KILL) are taken over, locks of
# live owners and of other hosts are not; TERM releases; a broken state directory never stops
# a backup. Hermetic: pg_dump, psql, curl, ... are fakes; every background process is
# recorded by PID and stopped by that PID in the exit trap; all sleeps are bounded.
#   bash tests/regress/lock-run.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_SRC="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill -KILL "$p" 2>/dev/null; done
    for p in "$TMP"/mark.*; do [ -f "$p" ] && kill -KILL "$(cat "$p")" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

mkdir -p "$TMP/bin" "$TMP/rec" "$TMP/home"
sed '1s|.*|#!/usr/bin/env bash|' "$BIN_SRC" > "$TMP/bin/t-pgsql"; chmod +x "$TMP/bin/t-pgsql"
ln -s "$BASH" "$TMP/bin/bash"
BIN="$TMP/bin/t-pgsql"
REC="$TMP/rec"; export REC
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/bin/sh
# Fake pg_dump: records start/end, optionally runs for DUMP_SLEEP seconds (bounded loop).
f=""
while [ $# -gt 0 ]; do [ "$1" = "-f" ] && f="$2"; shift; done
[ -n "$START_MARK" ] && echo $$ > "$START_MARK"
echo "start $(date +%s)" >> "$REC/pg_dump.log"
n=0; lim=$(( ${DUMP_SLEEP:-0} * 5 ))
while [ "$n" -lt "$lim" ]; do sleep 0.2; n=$((n + 1)); done
printf 'PGDMP\nfake dump\n' >> "$f"
echo "end $(date +%s)" >> "$REC/pg_dump.log"
exit 0
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/sh
echo "$*" >> "$REC/curl.log"
printf '{"ok":true}\n'
EOF
for t in psql pg_isready pg_dumpall xz bzip2; do printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$t"; done
chmod +x "$TMP/bin"/*
. "$ROOT/tests/regress/lib/fakes.sh"; fake_pg_tools "$TMP/bin"
export PATH="$TMP/bin:$PATH"
export HOME="$TMP/home"
export T_PGSQL_FROM_PASSWORD=x T_PGSQL_PASSWORD=x
unset XDG_STATE_HOME
STATE="$TMP/state"; export T_PGSQL_STATE_DIR="$STATE"
OUT="$TMP/out"
NOTIFY_ARG="telegram:121212:LOCKSECRET:-100"

# Arguments of a plain dump of database appdb (extra args appended)
dargs() { printf '%s\n' dump --from postgres@localhost/appdb --output "$OUT" --compress none \
    --min-size-ratio 0 --no-health-check --no-meta; }
# bg NAME [sleep-seconds] [extra args...]: start a dump in the background (PID in BGPID)
bg() {
    local name="$1" sl="$2"; shift 2
    local -a a; mapfile -t a < <(dargs)
    ( cd "$TMP" && exec env DUMP_SLEEP="$sl" START_MARK="$TMP/mark.$name" "$BASH" "$BIN" "${a[@]}" "$@" >"$TMP/$name.out" 2>&1 </dev/null ) &
    BGPID=$!; PIDS+=("$BGPID")
}
# fg NAME [extra args...]: run a dump to completion (status in rc, output in out)
fg() {
    local name="$1"; shift
    local -a a; mapfile -t a < <(dargs)
    out=$(cd "$TMP" && env DUMP_SLEEP=0 "$BASH" "$BIN" "${a[@]}" "$@" 2>&1 </dev/null); rc=$?
}
waitfile() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ -e "$1" ]; }
waitpid() { local i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$1" 2>/dev/null; }
reset() { rm -rf "${STATE:?}" "${OUT:?}" "${REC:?}"/* "$TMP"/mark.* "$TMP"/*.out; mkdir -p "$REC"; }
ndumps() { local n=0 f; for f in "$OUT"/*.dump; do [ -f "$f" ] && n=$((n + 1)); done; echo "$n"; }
nlocks() { ls -d "$STATE"/locks/*.lock 2>/dev/null | wc -l | tr -d ' '; }
mkmeta() { # dir pid host start
    [ -n "$1" ] && case "$1" in "$STATE"/locks/*) ;; *) return 1 ;; esac || return 1
    mkdir -p "$1"
    printf 'pid=%s\nhost=%s\nstart=%s\npstart=\ncmd=dump\njob=\nkey=x\n' "$2" "$3" "$4" > "$1/meta"
}

# 1. same base twice: the second run skips with 75, no notification; the first completes
reset
bg a 3; A=$BGPID
waitfile "$TMP/mark.a" || nok "first run started"
fg b --notify "$NOTIFY_ARG"
[ "$rc" -eq 75 ] && ok "overlapping run of the same base exits 75" || nok "overlapping run of the same base exits 75 (rc=$rc)"
case "$out" in *"Skipping"*"pid $A"*) ok "skip message names the holder pid" ;; *) nok "skip message names the holder pid: $out" ;; esac
case "$out" in *ERROR*) nok "skip is not logged as an error: $out" ;; *) ok "skip is not logged as an error" ;; esac
[ ! -e "$REC/curl.log" ] && ok "no notification was sent for the skipped run" || nok "no notification was sent for the skipped run"
waitpid "$A" || nok "first run finished"
wait "$A"; arc=$?
[ "$arc" -eq 0 ] && ok "first run completes normally" || nok "first run completes normally (rc=$arc)"
[ "$(ndumps)" -eq 1 ] && ok "exactly one dump was written" || nok "exactly one dump was written ($(ndumps))"
[ "$(nlocks)" -eq 0 ] && ok "lock removed after a successful run" || nok "lock removed after a successful run"
[ "$(ls -ld "$STATE" | cut -c1-10)" = "drwx------" ] && ok "state directory is private (0700)" || nok "state directory is private (0700)"
fg c
[ "$rc" -eq 0 ] && ok "base can be dumped again after release" || nok "base can be dumped again after release (rc=$rc)"

# 2. different bases (also prefix-overlapping names) run side by side
reset
bg a 3 --dump-name prod; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
fg b --dump-name prod_v2
[ "$rc" -eq 0 ] && ok "prod and prod_v2 do not block each other" || nok "prod and prod_v2 do not block each other (rc=$rc)"
fg c --dump-name other
[ "$rc" -eq 0 ] && ok "a different base runs while another is held" || nok "a different base runs while another is held (rc=$rc)"
fg d --dump-name prod
[ "$rc" -eq 75 ] && ok "same base prod is held" || nok "same base prod is held (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null

# 3. same base in another output directory is another target
reset
bg a 3; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
fg b --output "$TMP/out2"
[ "$rc" -eq 0 ] && ok "same base in another output directory runs" || nok "same base in another output directory runs (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null

# 4. --lock-wait waits for the holder, then proceeds
reset
bg a 2; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
fg b --lock-wait 15
[ "$rc" -eq 0 ] && ok "--lock-wait run succeeds once the holder is done" || nok "--lock-wait run succeeds once the holder is done (rc=$rc)"
[ "$(ndumps)" -eq 2 ] && ok "both dumps exist after waiting" || nok "both dumps exist after waiting ($(ndumps))"
aend=$(awk '$1=="end"{print $2; exit}' "$REC/pg_dump.log")
bstart=$(awk '$1=="start"{n++; if (n==2) print $2}' "$REC/pg_dump.log")
if [ -n "$aend" ] && [ -n "$bstart" ] && [ "$bstart" -ge "$aend" ]; then ok "second dump started after the first ended"; else nok "second dump started after the first ended ($aend/$bstart)"; fi
waitpid "$A"; wait "$A" 2>/dev/null
# a wait that is too short skips
reset
bg a 4; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
fg b --lock-wait 1
[ "$rc" -eq 75 ] && ok "--lock-wait shorter than the holder skips with 75" || nok "--lock-wait shorter than the holder skips with 75 (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null
fg b --lock-wait abc
[ "$rc" -eq 1 ] && ok "invalid --lock-wait is rejected" || nok "invalid --lock-wait is rejected (rc=$rc)"

# 5. --no-lock and --dry-run take no lock and ignore a held one
reset
bg a 3; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
fg b --no-lock
[ "$rc" -eq 0 ] && ok "--no-lock runs while the base is held" || nok "--no-lock runs while the base is held (rc=$rc)"
fg c --dry-run
[ "$rc" -eq 0 ] && ok "--dry-run is not blocked by a lock" || nok "--dry-run is not blocked by a lock (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null

# 6. TERM releases the lock
reset
bg a 3; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
[ "$(nlocks)" -eq 1 ] && ok "a running dump holds one lock" || nok "a running dump holds one lock ($(nlocks))"
kill -TERM "$A"
waitpid "$A" || nok "terminated run exited"
wait "$A" 2>/dev/null; arc=$?
[ "$arc" -eq 143 ] && ok "TERM ends the run with 143" || nok "TERM ends the run with 143 (rc=$arc)"
[ "$(nlocks)" -eq 0 ] && ok "TERM released the lock" || nok "TERM released the lock"

# 7. KILL leaves a lock that the next run recognises as stale
reset
bg a 5; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
kill -KILL "$A" 2>/dev/null; kill -KILL "$(cat "$TMP/mark.a")" 2>/dev/null
waitpid "$A"; { wait "$A"; } 2>/dev/null
[ "$(nlocks)" -eq 1 ] && ok "KILL leaves the lock behind" || nok "KILL leaves the lock behind ($(nlocks))"
LDIR=$(ls -d "$STATE"/locks/*.lock 2>/dev/null | head -1)
fg b
[ "$rc" -eq 0 ] && ok "next run takes over the stale lock" || nok "next run takes over the stale lock (rc=$rc: $out)"
case "$out" in *"stale lock"*"not running"*) ok "take-over names the stale owner" ;; *) nok "take-over names the stale owner: $out" ;; esac
[ "$(nlocks)" -eq 0 ] && ok "taken-over lock released at the end" || nok "taken-over lock released at the end"

# 8. other host: not taken over until the hard maximum; live pid of this host not taken over
reset
sleep 30 & SL=$!; PIDS+=("$SL")
bg a 5; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
kill -KILL "$A" 2>/dev/null; kill -KILL "$(cat "$TMP/mark.a")" 2>/dev/null
waitpid "$A"; { wait "$A"; } 2>/dev/null
LDIR=$(ls -d "$STATE"/locks/*.lock 2>/dev/null | head -1)
NOW=$(date +%s)
mkmeta "$LDIR" "$A" other.example.com "$NOW"
fg b
[ "$rc" -eq 75 ] && ok "a lock of another host is not taken over" || nok "a lock of another host is not taken over (rc=$rc)"
mkmeta "$LDIR" "$A" other.example.com 1
fg b
[ "$rc" -eq 0 ] && ok "a lock of another host past the hard maximum is taken over" || nok "a lock of another host past the hard maximum is taken over (rc=$rc)"
mkmeta "$LDIR" "$SL" "$(hostname)" "$NOW"
fg b
[ "$rc" -eq 75 ] && ok "a lock of a live pid on this host is not taken over" || nok "a lock of a live pid on this host is not taken over (rc=$rc)"
mkmeta "$LDIR" "$SL" "$(hostname)" $((NOW - 100))
mapfile -t DA < <(dargs)
out=$(cd "$TMP" && T_PGSQL_LOCK_MAX_AGE=10 DUMP_SLEEP=0 "$BASH" "$BIN" "${DA[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "a live owner older than T_PGSQL_LOCK_MAX_AGE is taken over" || nok "a live owner older than T_PGSQL_LOCK_MAX_AGE is taken over (rc=$rc)"
kill -KILL "$SL" 2>/dev/null; { wait "$SL"; } 2>/dev/null
# 9. unusable state directory: the backup still runs, with a warning
reset
: > "$TMP/afile"
out=$(cd "$TMP" && T_PGSQL_STATE_DIR="$TMP/afile/state" DUMP_SLEEP=0 "$BASH" "$BIN" "${DA[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "unusable state directory: run still succeeds" || nok "unusable state directory: run still succeeds (rc=$rc)"
case "$out" in *"without a lock"*) ok "unusable state directory is reported" ;; *) nok "unusable state directory is reported: $out" ;; esac
[ "$(ndumps)" -eq 1 ] && ok "the dump was written without a lock" || nok "the dump was written without a lock"
# a lock directory that cannot be created (locks is a plain file)
reset
mkdir -p "$STATE"; : > "$STATE/locks"
fg b
[ "$rc" -eq 0 ] && ok "locks path that is a file: run still succeeds" || nok "locks path that is a file: run still succeeds (rc=$rc)"

# 10. odd characters in names give safe lock file names and still lock
reset
bg a 3 --dump-name 'we ird$x;y*'; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
bad=0
for f in "$STATE"/locks/*; do case "$(basename "$f")" in *[!A-Za-z0-9._-]*) bad=1 ;; esac; done
[ "$bad" -eq 0 ] && [ "$(nlocks)" -eq 1 ] && ok "lock file name only has safe characters" || nok "lock file name only has safe characters"
fg b --dump-name 'we ird$x;y*'
[ "$rc" -eq 75 ] && ok "odd base name is still locked" || nok "odd base name is still locked (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null

# 11. lock_wait / no_lock from a config file, and job keys are known
reset
printf 'lock_wait: abc\n' > "$TMP/bad.conf"
fg b --config "$TMP/bad.conf"
[ "$rc" -eq 1 ] && ok "lock_wait from --config is validated" || nok "lock_wait from --config is validated (rc=$rc)"
printf 'no_lock: true\n' > "$TMP/nolock.conf"
bg a 3; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
fg b --config "$TMP/nolock.conf"
[ "$rc" -eq 0 ] && ok "no_lock from --config disables the lock" || nok "no_lock from --config disables the lock (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null

# 12. batch: a skipped job is reported, is not a failure and does not stop the batch
reset
mkjob() { # name db extra
    printf '  %s:\n    command: dump\n    from: postgres@localhost/%s\n    password: x\n    output: %s\n    no_meta: true\n    no_health_check: true\n    compress: none\n    min_size_ratio: 0\n' "$1" "$2" "$OUT"
    [ -n "$3" ] && printf '%s\n' "$3"
}
{ echo "jobs:"; mkjob job-a appdb; mkjob job-c otherdb; } > "$TMP/jobs.yaml"
bg a 3; A=$BGPID
waitfile "$TMP/mark.a" || nok "run a started"
out=$(cd "$TMP" && DUMP_SLEEP=0 "$BASH" "$BIN" batch all --yaml "$TMP/jobs.yaml" 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "batch with a locked job exits 0" || nok "batch with a locked job exits 0 (rc=$rc)"
case "$out" in *"Skipped (locked): job-a"*) ok "batch reports the skipped job" ;; *) nok "batch reports the skipped job: $out" ;; esac
case "$out" in *"Failed:"*) nok "a skipped job is not counted as failed: $out" ;; *) ok "a skipped job is not counted as failed" ;; esac
compgen -G "$OUT/otherdb_*" >/dev/null && ok "the next job still ran after the skip" || nok "the next job still ran after the skip"
out=$(cd "$TMP" && DUMP_SLEEP=0 "$BASH" "$BIN" batch job-a --yaml "$TMP/jobs.yaml" 2>&1 </dev/null); rc=$?
[ "$rc" -eq 75 ] && ok "single locked job via batch exits 75" || nok "single locked job via batch exits 75 (rc=$rc)"
waitpid "$A"; wait "$A" 2>/dev/null
# two jobs of one parallel batch with the same target: one runs, one is skipped
reset
{ echo "jobs:"; mkjob job-a appdb; mkjob job-b appdb; } > "$TMP/jobs.yaml"
out=$(cd "$TMP" && DUMP_SLEEP=8 "$BASH" "$BIN" batch all --yaml "$TMP/jobs.yaml" --parallel 2 2>&1 </dev/null); rc=$?
[ "$rc" -eq 0 ] && ok "parallel batch with one locked job exits 0" || nok "parallel batch with one locked job exits 0 (rc=$rc)"
[ "$(printf '%s\n' "$out" | grep -c 'Skipped (locked)')" -eq 1 ] && ok "exactly one of the two jobs was skipped" || nok "exactly one of the two jobs was skipped: $out | pg_dump.log: $(tr '\n' ';' < "$REC/pg_dump.log" 2>/dev/null) | locks: $(ls "$STATE/locks" 2>/dev/null | tr '\n' ' ')"
[ "$(ndumps)" -eq 1 ] && ok "only one dump was written" || nok "only one dump was written ($(ndumps))"
[ "$(nlocks)" -eq 0 ] && ok "batch left no lock behind" || nok "batch left no lock behind"

# 13. two plain runs started at the same instant: exactly one may hold the lock (race probe)
raced=0
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
    reset
    bg x 2; XP=$BGPID; bg y 2; YP=$BGPID
    waitpid "$XP"; waitpid "$YP"; wait "$XP" "$YP" 2>/dev/null
    if [ "$(grep -c '^start' "$REC/pg_dump.log" 2>/dev/null)" -ne 1 ]; then
        raced=1
        nok "simultaneous start $n: both runs held the lock | x: $(tr '\n' ' ' < "$TMP/x.out" | cut -c1-600) | y: $(tr '\n' ' ' < "$TMP/y.out" | cut -c1-600)"
        break
    fi
done
[ "$raced" -eq 0 ] && ok "12 simultaneous starts: exactly one run held the lock each time"

[ "$FAIL" -eq 0 ]
