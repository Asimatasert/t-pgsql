#!/usr/bin/env bash
# Regression: run history (<state dir>/history.tsv) written by dump runs, and the
# "status" command that reads it. Hermetic: pg_dump, psql, curl, ssh and friends are faked.
#   bash tests/regress/status-history.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; REC="$TMP/rec"
mkdir -p "$FAKE" "$REC"
# pg_dump: writes a PGDMP file of DUMP_BYTES bytes; exits 1 (leaving a partial file) when DUMP_FAIL=1.
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    if [ "$1" = -f ]; then
        { printf 'PGDMP'; printf '%*s' $((${DUMP_BYTES:-100} - 5)) '' | tr ' ' x; } > "$2"
    fi
    shift
done
[ "$DUMP_FAIL" = 1 ] && exit 1
exit 0
EOF
for t in psql pg_isready createdb dropdb pg_dumpall pg_restore xz bzip2 zstd ssh scp curl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"
unset XDG_STATE_HOME CURRENT_JOB_NAME NO_COLOR

OUT="$TMP/out"
ST="$TMP/state"
export T_PGSQL_STATE_DIR="$ST"
HF="$ST/history.tsv"
NOW=$(date +%s)
fresh() { rm -rf "$OUT" "$ST"; mkdir -p "$OUT"; }
# dumpit BYTES [args]  -> $out (output) and $rc
dumpit() { local nb="$1"; shift
    out=$(DUMP_BYTES="$nb" "$BASH" "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --compress none --no-meta \
        "$@" </dev/null 2>&1); rc=$?; }
lastline() { tail -n 1 "$HF"; }
field() { lastline | awk -F'\t' -v n="$1" '{print $n}'; }
# hist_add EPOCH COMMAND NAME STATUS RC DURATION SIZE MESSAGE
hist_add() { mkdir -p "$ST"; printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "2026-01-01T00:00:00Z" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$HF"; }
st() { sout=$("$BASH" "$BIN" status "$@" 2>&1 </dev/null); src=$?; }

# 1. successful dump
fresh; dumpit 100
[ $rc -eq 0 ] && ok "dump succeeds" || nok "dump failed: $out"
[ "$(wc -l < "$HF" | tr -d ' ')" = 1 ] && ok "exactly one history line" || nok "history lines: $(cat "$HF" 2>&1)"
[ "$(lastline | awk -F'\t' '{print NF}')" = 9 ] && ok "nine tab separated fields" || nok "fields: $(lastline)"
[ "$(field 3)" = dump ] && [ "$(field 4)" = appdb ] && [ "$(field 5)" = ok ] && [ "$(field 6)" = 0 ] && ok "command/name/status/exit recorded" || nok "line: $(lastline)"
case "$(field 2)" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ok "iso8601 UTC time" ;; *) nok "time: $(field 2)" ;; esac
[ "$(field 8)" = 100 ] && ok "size of the artifact recorded" || nok "size: '$(field 8)'"
perm=$(ls -l "$HF" | cut -c1-10); [ "$perm" = "-rw-------" ] && ok "history file is 0600" || nok "perm $perm"
sperm=$(ls -ld "$ST" | cut -c1-10); [ "$sperm" = "drwx------" ] && ok "state dir is 0700" || nok "perm $sperm"

# 2. failed dump keeps its exit status and is recorded
fresh; out=$(DUMP_FAIL=1 "$BASH" "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --compress none </dev/null 2>&1); rc=$?
[ $rc -eq 1 ] && ok "failed dump still exits 1" || nok "exit status $rc"
[ "$(field 5)" = failed ] && [ "$(field 6)" = 1 ] && [ -z "$(field 8)" ] && [ -n "$(field 9)" ] && ok "failure recorded with reason and no size" || nok "line: $(lastline)"

# 3. usage failure before any connection is still recorded, one line
fresh; out=$("$BASH" "$BIN" dump --output "$OUT" </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(wc -l < "$HF" | tr -d ' ')" = 1 ] && [ "$(field 5)" = failed ] && ok "early failure recorded once" || nok "rc=$rc line: $(cat "$HF" 2>&1)"

# 4. shrink guard -> suspect
fresh; { printf 'PGDMP'; printf '%1000s' '' | tr ' ' x; } > "$OUT/appdb_20200101_000000.dump"
dumpit 400
[ $rc -ne 0 ] && [ "$(field 5)" = suspect ] && ok "shrink guard recorded as suspect" || nok "rc=$rc line: $(lastline)"
[ "$(field 8)" = 400 ] && ok "suspect size recorded" || nok "size '$(field 8)'"

# 5. dry-run writes nothing; status and list write nothing
fresh; dumpit 100 --dry-run
[ $rc -eq 0 ] && [ ! -e "$HF" ] && ok "dry-run writes no history" || nok "dry-run history: $(cat "$HF" 2>&1)"
st; [ ! -e "$ST" ] && ok "status creates nothing on a fresh machine" || nok "status created $ST"
[ $src -eq 0 ] && ok "status works without history (exit 0)" || nok "status rc=$src: $sout"

# 6. job name and skip-if-recent
fresh; CURRENT_JOB_NAME=nightly dumpit 100
[ "$(field 4)" = nightly ] && ok "job name recorded" || nok "name '$(field 4)'"
CURRENT_JOB_NAME=nightly dumpit 100 --skip-if-recent 24h
[ "$(field 5)" = skipped ] && [ "$(field 6)" = 0 ] && ok "skipped run recorded" || nok "line: $(lastline)"

# 7. rotation
fresh; i=0; while [ $i -lt 2000 ]; do hist_add "$NOW" dump padded ok 0 1 1 ""; i=$((i + 1)); done
dumpit 100
n=$(wc -l < "$HF" | tr -d ' ')
[ "$n" = 1000 ] && ok "trimmed to 1000 lines past 2000" || nok "lines after rotation: $n"
[ "$(field 4)" = appdb ] && ok "newest line survives the trim" || nok "last: $(lastline)"
[ ! -e "$ST/history.lock" ] && ok "lock released" || nok "lock left behind"
perm=$(ls -l "$HF" | cut -c1-10); [ "$perm" = "-rw-------" ] && ok "trimmed file is 0600" || nok "perm $perm"

# 8. status summary: prod and prod_v2 are different names; dumps kept per base
fresh
touch "$OUT/prod_20260101_010101.dump" "$OUT/prod_20260102_010101.dump" "$OUT/prod_v2_20260101_010101.dump" "$OUT/prod_20260103_010101.dump.suspect"
hist_add $((NOW - 3 * 3600)) dump prod ok 0 12 2048 ""
hist_add $((NOW - 600)) dump prod_v2 failed 1 3 "" "connection refused"
hist_add $((NOW - 90000)) dump prod_v2 ok 0 4 1048576 ""
st --output "$OUT"
[ $src -eq 0 ] && ok "status exits 0 even when a name failed" || nok "rc=$src"
echo "$sout" | awk '$1=="prod" && /3h ago/ && /ok/ && /2 / && /1 .suspect/ {f=1} END{exit !f}' && ok "prod row: age, result, 2 dumps kept, suspect note" || nok "prod row: $sout"
echo "$sout" | awk '$1=="prod_v2" && /failed/ && /connection refused/ && /last ok 1d ago/ {f=1} END{exit !f}' && ok "prod_v2 row: failure, reason, last success age" || nok "prod_v2 row: $sout"
echo "$sout" | awk '$1=="prod_v2" && $0 ~ / 1 / {f=1} END{exit !f}' && ok "prod_v2 counts only its own dump" || nok "prod_v2 count: $sout"
echo "$sout" | grep -q $'\033' && nok "colour codes leaked into non-terminal output" || ok "no colour on a pipe"
NO_COLOR=1 "$BASH" "$BIN" status --output "$OUT" 2>&1 | grep -q $'\033' && nok "NO_COLOR ignored" || ok "NO_COLOR clean"
st --output "$TMP/does-not-exist"
[ $src -eq 0 ] && ok "missing output directory is fine" || nok "rc=$src $sout"
# a base found only in the output directory is listed as never
touch "$OUT/orphan_20260101_010101.dump"
st --output "$OUT"
echo "$sout" | awk '$1=="orphan" && /never/ {f=1} END{exit !f}' && ok "output-dir-only base shown as never" || nok "orphan: $sout"

# 9. corrupt lines are skipped
printf 'garbage line\n12\tonly\n\n' >> "$HF"
printf 'abc\tx\tdump\tbad\tok\t0\t1\t\t\n' >> "$HF"
st --output "$OUT"
[ $src -eq 0 ] && echo "$sout" | grep -q '^prod ' && ! echo "$sout" | grep -q '^bad' && ok "corrupt lines skipped" || nok "corrupt: rc=$src $sout"

# 10. --yaml: one row per job, never-run job shown as never
cat > "$TMP/jobs.yaml" <<'EOF'
jobs:
  prod:
    command: dump
    from:
      database: prod
  weekly-x:
    command: dump
    dump_name: prod_v2
EOF
st --yaml "$TMP/jobs.yaml" --output "$OUT"
echo "$sout" | awk '$1=="prod" && /ok/ {f=1} END{exit !f}' && echo "$sout" | awk '$1=="weekly-x" && /never/ {f=1} END{exit !f}' && ! echo "$sout" | grep -q '^prod_v2' && ok "yaml mode: one row per job, never-run job" || nok "yaml: $sout"
st --yaml "$TMP/missing.yaml"
[ $src -eq 2 ] && ok "missing --yaml file is a usage error (2)" || nok "rc=$src"

# 11. --json
fresh
hist_add $((NOW - 60)) dump 'we ird' failed 1 2 "" 'has "quotes" and back\slash'
hist_add $((NOW - 7200)) dump prod ok 0 5 4096 ""
st --json --output "$OUT"
case "$sout" in "["*"]") ok "json is one array" ;; *) nok "json shape: $sout" ;; esac
if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$sout" | python3 -c '
import json, sys
d = json.load(sys.stdin)
m = {r["name"]: r for r in d}
assert m["we ird"]["message"] == "has \"quotes\" and back\\slash", m["we ird"]
assert m["prod"]["size_bytes"] == 4096 and m["prod"]["duration_s"] == 5
assert isinstance(m["prod"]["dumps_kept"], int) and m["we ird"]["size_bytes"] is None
assert m["prod"]["stale"] is False
' 2>"$TMP/py.err" && ok "json parses; escapes and numbers correct" || nok "json invalid: $(cat "$TMP/py.err")"
else
    echo "$sout" | grep -q '"message": "has \\"quotes\\" and back\\\\slash"' && echo "$sout" | grep -q '"size_bytes": 4096' && ok "json escapes (shape check, no python3)" || nok "json escapes: $sout"
fi
st --json --output "$OUT" --name nobody
case "$sout" in "["*"]") ok "json for an unknown name is still an array" ;; *) nok "json unknown: $sout" ;; esac

# 12. --max-age exit codes
fresh
hist_add $((NOW - 3600)) dump prod ok 0 1 1 ""
st --output "$OUT" --max-age 2h
[ $src -eq 0 ] && ok "max-age: fresh success -> 0" || nok "rc=$src $sout"
st --output "$OUT" --max-age 30m
[ $src -eq 3 ] && ok "max-age: old success -> 3" || nok "rc=$src $sout"
hist_add $((NOW - 60)) dump prod failed 1 1 "" "boom"
st --output "$OUT" --max-age 2h
[ $src -eq 0 ] && ok "max-age: older success still within limit, newest failed -> 0" || nok "rc=$src"
hist_add $((NOW - 30)) dump lonely failed 1 1 "" "boom"
st --output "$OUT" --max-age 26h
[ $src -eq 3 ] && ok "max-age: a name without any success -> 3" || nok "rc=$src $sout"
st --output "$OUT" --name prod --max-age 26h
[ $src -eq 0 ] && ok "max-age limited by --name" || nok "rc=$src"
st --name ghost --max-age 26h --output "$OUT"
[ $src -eq 3 ] && ok "max-age: never-ran name -> 3" || nok "rc=$src"
st --max-age 26x; [ $src -eq 2 ] && ok "bad --max-age -> 2" || nok "rc=$src"
st --max-age 26; [ $src -ne 2 ] && ok "--max-age without unit is bare seconds (accepted)" || nok "rc=$src"

# 13. --limit history view
fresh
i=1; while [ $i -le 5 ]; do hist_add $((NOW - 1000 + i)) dump hv ok 0 $i $((i * 10)) ""; i=$((i + 1)); done
hist_add $((NOW - 500)) dump other ok 0 1 1 ""
st --name hv --limit 3 --output "$OUT"
[ "$(echo "$sout" | grep -c ' dump ')" = 3 ] && ok "--limit shows N runs" || nok "limit: $sout"
echo "$sout" | grep -q 'other' && nok "--limit leaked another name" || ok "--limit filtered by name"
st --limit 3; [ $src -eq 2 ] && ok "--limit without --name -> 2" || nok "rc=$src"
st --name hv --limit 0; [ $src -eq 2 ] && ok "--limit 0 -> 2" || nok "rc=$src"
st --name hv --limit 2 --json
case "$sout" in "["*"]") ok "--limit --json is an array" ;; *) nok "limit json: $sout" ;; esac

# 14. unwritable state directory: runs succeed, status still reads
if [ "$(id -u)" != 0 ]; then
    fresh; hist_add $((NOW - 60)) dump prod ok 0 1 1 ""
    chmod 500 "$ST"; chmod 400 "$HF"
    dumpit 100
    [ $rc -eq 0 ] && ok "dump succeeds with an unwritable state dir" || nok "rc=$rc $out"
    [ "$(wc -l < "$HF" | tr -d ' ')" = 1 ] && ok "nothing written to the read-only history" || nok "history changed"
    st --output "$OUT"
    [ $src -eq 0 ] && echo "$sout" | grep -q '^prod ' && ok "status reads a read-only state dir" || nok "rc=$src $sout"
    chmod 700 "$ST"; chmod 600 "$HF"
fi

# 15. a symlinked history file is never followed
fresh; mkdir -p "$ST"; : > "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$HF"
dumpit 100
[ $rc -eq 0 ] && [ ! -s "$TMP/elsewhere" ] && ok "symlinked history is not written through" || nok "symlink followed or run failed (rc=$rc)"

# 16. no secrets in the recorded message (the connection string is echoed by the error text)
for conn in 'ssh://u:s3cretpw@@h:x:y/db' 'postgres://u:s3cretpw@/'; do
    fresh; out=$("$BASH" "$BIN" dump --from "$conn" --output "$OUT" </dev/null 2>&1); rc=$?
    [ "$rc" -ne 0 ] && [ -s "$HF" ] && ok "bad connection recorded" || nok "no history for bad connection rc=$rc"
    grep -q 's3cretpw' "$HF" 2>/dev/null && nok "password leaked into history: $(cat "$HF")" || ok "no password in the history line"
    grep -q 'Invalid source connection' "$HF" 2>/dev/null && ok "reason recorded" || nok "reason missing: $(cat "$HF" 2>&1)"
done

exit $FAIL
