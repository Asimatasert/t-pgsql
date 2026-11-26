#!/usr/bin/env bash
# Regression: --min-size-ratio. A new dump much smaller than the previous dump of the
# same base name must not rotate anything: older dumps stay, the new file is kept as
# <name>.suspect, the job fails and a failure notification goes out.
# Hermetic: pg_dump, pg_restore, psql, ssh, scp, curl and zstd are faked.
#   bash tests/regress/shrink-guard.sh   (T_PGSQL_BIN overrides ./t-pgsql)
if [ "${BASH_VERSINFO[0]}" -lt 4 ] && [ -x /opt/homebrew/bin/bash ]; then exec /opt/homebrew/bin/bash "$0" "$@"; fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

FAKE="$TMP/fake"; REC="$TMP/rec"; SB="$TMP/sandbox"
mkdir -p "$FAKE" "$REC" "$SB"

# pg_dump writes a PGDMP header padded with filler to exactly DUMP_BYTES bytes.
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    if [ "$1" = -f ]; then
        { printf 'PGDMP'; printf '%*s' $((DUMP_BYTES - 5)) '' | tr ' ' x; } > "$2"
        echo "pg_dump -f $2" >> "$REC/pg_dump.log"
    fi
    shift
done
exit 0
EOF
# zstd: -t passes, -dc prints the file, compression turns FILE into FILE.zst (same bytes,
# or ZSTD_BYTES bytes of PGDMP-headed data when set, to model a better ratio).
cat > "$FAKE/zstd" <<'EOF'
#!/usr/bin/env bash
for last; do :; done
case " $* " in
    *" -t "*) exit 0 ;;
    *" -dc "*) cat "$last"; exit 0 ;;
    *) if [ -n "$ZSTD_BYTES" ]; then
           { printf 'PGDMP'; printf '%*s' $((ZSTD_BYTES - 5)) '' | tr ' ' x; } > "$last.zst"; rm -f "$last"
       else
           cp "$last" "$last.zst" && rm -f "$last"
       fi
       exit 0 ;;
esac
EOF
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
n=$(ls "$REC"/curl.*.argv 2>/dev/null | wc -l | tr -d ' '); n=$((n + 1))
printf '%s\n' "$@" > "$REC/curl.$n.argv"
if [ ! -t 0 ]; then cat > "$REC/curl.$n.stdin"; fi
printf '{"ok":true}\n'
EOF
for t in psql pg_isready createdb dropdb pg_dumpall xz bzip2 pg_restore; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
cat > "$FAKE/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
cmd="${cmd//\/tmp\/t-pgsql/$SB/t-pgsql}"
sed "s#/tmp/t-pgsql#$SB/t-pgsql#g" | sh -c "$cmd"
EOF
cat > "$FAKE/scp" <<'EOF'
#!/usr/bin/env bash
a=("$@"); src="${a[$((${#a[@]}-2))]}"; dst="${a[$((${#a[@]}-1))]}"
src="${src#*@*:}"; src="${src//\/tmp\/t-pgsql/$SB/t-pgsql}"
cp "$src" "$dst"
EOF
chmod +x "$FAKE"/*
export SB REC
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

OUT="$TMP/out"; ARC="$TMP/archive"
NOTIFY_ARG="telegram:121212:SHRINKSECRET:-100"

# mk FILE BYTES TOUCHSTAMP: PGDMP-headed file of exactly BYTES bytes
mk() { { printf 'PGDMP'; printf '%*s' $(($2 - 5)) '' | tr ' ' x; } > "$1"; touch -t "$3" "$1"; }
seed() { rm -rf "$OUT" "$ARC" "$SB/t-pgsql" "$REC"/*; mkdir -p "$OUT" "$SB/t-pgsql"; }
# dumpit NEWBYTES [args...]  -> output in $out, status in $rc
dumpit() { local nb="$1"; shift
    out=$(DUMP_BYTES="$nb" "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --compress none \
        --notify "$NOTIFY_ARG" "$@" </dev/null 2>&1); rc=$?; }
has() { ls "$OUT" | grep -q -E "$1"; }
count() { ls "$OUT" | grep -c -E "$1"; }
NEWPAT='^appdb_[0-9]{8}_[0-9]{6}(_[0-9]+)?\.dump$'
notified() { cat "$REC"/curl.*.argv "$REC"/curl.*.stdin 2>/dev/null | grep -q "$1"; }

# 1. first dump: no previous dump, passes
seed; dumpit 100 --keep 1
[ $rc -eq 0 ] && ok "first dump passes" || nok "first dump failed: $out"

# 2. clear shrink: fails, nothing rotated, new file set aside, notification sent
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_20190101_000000.dump" 1000 201901010000
dumpit 400 --keep 1
[ $rc -ne 0 ] && ok "shrunk dump exits non-zero" || nok "shrunk dump reported success"
[ -e "$OUT/appdb_20200101_000000.dump" ] && [ -e "$OUT/appdb_20190101_000000.dump" ] && ok "older dumps untouched (keep-N skipped)" || nok "older dump rotated: $(ls "$OUT")"
[ "$(count '\.suspect$')" -eq 1 ] && ok "new dump kept as .suspect" || nok "no .suspect file: $(ls "$OUT")"
[ "$(ls "$OUT" | grep -v '_000000\.' | grep -c -E "$NEWPAT")" -eq 0 ] && ok "no dump-pattern file left for the new dump" || nok "new dump still matches a dump pattern: $(ls "$OUT")"
[ "$(ls "$OUT" | grep -c '\.meta$')" -eq 0 ] && ok "no metadata written" || nok "metadata written: $(ls "$OUT")"
case "$out" in *"400 bytes"*"1000 bytes"*"40%"*"50%"*"--min-size-ratio 0"*) ok "error names both sizes, ratio, threshold and the override" ;; *) nok "error text incomplete: $out" ;; esac
case "$out" in *appdb_20200101_000000.dump*".suspect"*|*".suspect"*appdb_20200101_000000.dump*) ok "error names both files" ;; *) nok "files not named: $out" ;; esac
notified "Shrink guard" && ok "failure notification carries the shrink details" || nok "no shrink notification"
notified "❌" && ok "failure notification sent" || nok "no failure notification"

# 3. threshold boundaries
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
dumpit 500 --keep 5
[ $rc -eq 0 ] && ok "exactly at the threshold passes" || nok "exact threshold failed: $out"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
dumpit 499 --keep 5
[ $rc -ne 0 ] && ok "one byte under the threshold fails" || nok "499/1000 passed"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
dumpit 5000 --keep 5
[ $rc -eq 0 ] && ok "a larger new dump passes" || nok "larger dump failed: $out"

# 4. ratio 0 disables, ratio 100 demands no shrink
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
dumpit 10 --keep 5 --min-size-ratio 0
[ $rc -eq 0 ] && ok "--min-size-ratio 0 disables the check" || nok "ratio 0 failed: $out"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
dumpit 999 --keep 5 --min-size-ratio 100
[ $rc -ne 0 ] && ok "ratio 100 rejects a 1-byte shrink" || nok "ratio 100 passed 999/1000"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
dumpit 1000 --keep 5 --min-size-ratio 100
[ $rc -eq 0 ] && ok "ratio 100 accepts an equal size" || nok "ratio 100 rejected equal size: $out"

# 5. option validation
for bad in 101 -1 abc 5.5 ""; do
    seed; out=$("$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --min-size-ratio "$bad" </dev/null 2>&1); rc=$?
    [ $rc -ne 0 ] && case "$out" in *"min-size-ratio"*) true ;; *) false ;; esac && ok "invalid ratio '$bad' rejected" || nok "invalid ratio '$bad' accepted (rc=$rc): $out"
done

# 6. previous dump file missing but its metadata present: first-run behaviour
seed; printf 'x\n' > "$OUT/appdb_20200101_000000.dump.meta"
dumpit 10 --keep 1
[ $rc -eq 0 ] && ok "metadata without a dump file does not trigger the guard" || nok "orphan metadata triggered the guard: $out"

# 7. previous dump of size 0 passes
seed; : > "$OUT/appdb_20200101_000000.dump"; touch -t 202001010000 "$OUT/appdb_20200101_000000.dump"
dumpit 10 --keep 5
[ $rc -eq 0 ] && ok "empty previous dump passes" || nok "empty previous failed: $out"

# 8. previous dump of a different compression is compared as is
seed; mk "$OUT/appdb_20200101_000000.dump.zst" 1000 202001010000
out=$(DUMP_BYTES=1000 ZSTD_BYTES=300 "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --compress zstd --keep 5 </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && has '\.dump\.zst\.suspect$' && ok "compressed result (300) vs previous (1000) fails and is set aside" || nok "compression switch handling wrong (rc=$rc): $(ls "$OUT")"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
out=$(DUMP_BYTES=1000 ZSTD_BYTES=600 "$BIN" dump --from "postgres@localhost/appdb" --output "$OUT" --compress zstd --keep 5 </dev/null 2>&1); rc=$?
[ $rc -eq 0 ] && ok "compressed result at 60% of an uncompressed previous passes" || nok "compression pass case failed: $out"

# 9. two bases in one directory never compare against each other
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_v2_20210101_000000.dump" 100000 202101010000
dumpit 600 --keep 5
[ $rc -eq 0 ] && ok "appdb is not compared with appdb_v2" || nok "base mix-up: $out"
[ -e "$OUT/appdb_v2_20210101_000000.dump" ] && ok "appdb_v2 dump untouched" || nok "appdb_v2 dump removed"

# 10. archive tier and --keep 1: nothing moved or deleted when the guard fails
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_20190101_000000.dump" 1000 201901010000
dumpit 100 --keep 1 --archive-output "$ARC" --archive-keep 1
[ $rc -ne 0 ] && [ ! -e "$ARC" -o -z "$(ls "$ARC" 2>/dev/null)" ] && [ -e "$OUT/appdb_20190101_000000.dump" ] && [ -e "$OUT/appdb_20200101_000000.dump" ] \
    && ok "archive/keep handling skipped on failure" || nok "archive handling ran (rc=$rc): out=$(ls "$OUT") arc=$(ls "$ARC" 2>/dev/null)"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_20190101_000000.dump" 1000 201901010000
dumpit 1000 --keep 1 --archive-output "$ARC" --archive-keep 1
[ $rc -eq 0 ] && [ -n "$(ls "$ARC" 2>/dev/null)" ] && ok "control: archive move still runs on success" || nok "control run did not archive (rc=$rc): $out"

# 11. retention flags: old dumps survive a failed guard
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_20200102_000000.dump" 1000 202001020000
mk "$OUT/appdb_20200103_000000.dump" 1000 202001030000
dumpit 100 --retention --retention-daily 1
[ $rc -ne 0 ] && [ "$(count '^appdb_2020010[123]_000000\.dump$')" -eq 3 ] && ok "retention not applied on failure" || nok "retention ran (rc=$rc): $(ls "$OUT")"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$OUT/appdb_20200102_000000.dump" 1000 202001020000
mk "$OUT/appdb_20200103_000000.dump" 1000 202001030000
dumpit 1000 --retention --retention-daily 1
[ $rc -eq 0 ] && [ "$(count '^appdb_2020010[123]_000000\.dump$')" -lt 3 ] && ok "control: retention still runs on success" || nok "retention control (rc=$rc): $(ls "$OUT")"

# 12. SSH path with --from-keep 1: source copies kept, local rotation skipped
SRC="ssh://u@192.0.2.1/postgres@localhost/appdb"
sdump() { local nb="$1"; shift
    out=$(DUMP_BYTES="$nb" "$BIN" dump --from "$SRC" --output "$OUT" --compress none --keep 1 --from-keep 1 \
        --notify "$NOTIFY_ARG" "$@" </dev/null 2>&1); rc=$?; }
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$SB/t-pgsql/appdb_20190101_000000.dump" 1000 201901010000
mk "$SB/t-pgsql/appdb_20190201_000000.dump" 1000 201902010000
sdump 100
[ $rc -ne 0 ] && ok "ssh shrunk dump fails" || nok "ssh shrunk dump passed"
[ -e "$OUT/appdb_20200101_000000.dump" ] && has '\.suspect$' && ok "ssh: local old dump kept, new set aside" || nok "ssh local state wrong: $(ls "$OUT")"
[ -e "$SB/t-pgsql/appdb_20190101_000000.dump" ] && [ -e "$SB/t-pgsql/appdb_20190201_000000.dump" ] && ok "ssh: source-side rotation skipped" || nok "source copies rotated: $(ls "$SB/t-pgsql")"
[ "$(ls "$SB/t-pgsql" | grep -c '^appdb_')" -eq 3 ] && ok "ssh: the new source copy is kept too" || nok "source copy count wrong: $(ls "$SB/t-pgsql")"
notified "Shrink guard" && ok "ssh: failure notification carries the shrink details" || nok "ssh: no shrink notification"
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
mk "$SB/t-pgsql/appdb_20190101_000000.dump" 1000 201901010000
mk "$SB/t-pgsql/appdb_20190201_000000.dump" 1000 201902010000
sdump 1000
[ $rc -eq 0 ] && [ "$(ls "$SB/t-pgsql" | grep -c '^appdb_')" -eq 1 ] && ok "control: ssh success still rotates the source" || nok "ssh control (rc=$rc): $(ls "$SB/t-pgsql")"
# ssh with source-side compression: guard runs once on the final artifact
seed; mk "$OUT/appdb_20200101_000000.dump.zst" 1000 202001010000
out=$(DUMP_BYTES=1000 ZSTD_BYTES=200 "$BIN" dump --from "$SRC" --output "$OUT" --compress zstd --compress-where source \
    --keep 1 --from-keep 1 </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'Shrink guard: the new dump')" -eq 1 ] && ok "ssh + source compression: guard evaluated once" || nok "ssh compressed case (rc=$rc): $out"
# ssh with target-side compression: sizes compared after compression
seed; mk "$OUT/appdb_20200101_000000.dump.zst" 1000 202001010000
mk "$SB/t-pgsql/appdb_20190101_000000.dump" 1000 201901010000
out=$(DUMP_BYTES=1000 ZSTD_BYTES=200 "$BIN" dump --from "$SRC" --output "$OUT" --compress zstd \
    --keep 1 --from-keep 1 </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(printf '%s\n' "$out" | grep -c 'Shrink guard: the new dump')" -eq 1 ] && [ -e "$SB/t-pgsql/appdb_20190101_000000.dump" ] \
    && ok "ssh + target compression: compared after compression, once, source kept" || nok "ssh target-compress case (rc=$rc): $out"
seed; mk "$OUT/appdb_20200101_000000.dump.zst" 1000 202001010000
out=$(DUMP_BYTES=1000 ZSTD_BYTES=600 "$BIN" dump --from "$SRC" --output "$OUT" --compress zstd \
    --keep 1 --from-keep 1 </dev/null 2>&1); rc=$?
[ $rc -eq 0 ] && ok "ssh + target compression passes at 60%" || nok "ssh target-compress pass case failed: $out"

# 13. clone uses the same dump path
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
out=$(DUMP_BYTES=100 "$BIN" clone --from "postgres@localhost/appdb" --to "postgres@localhost/copydb" --output "$OUT" \
    --compress none --force </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && has '\.suspect$' && [ -e "$OUT/appdb_20200101_000000.dump" ] && ok "clone is stopped by the guard" || nok "clone not guarded (rc=$rc): $out"

# 14. dry run: no check, nothing written
seed; mk "$OUT/appdb_20200101_000000.dump" 1000 202001010000
before=$(ls "$OUT")
dumpit 10 --keep 1 --dry-run
[ $rc -eq 0 ] && [ "$(ls "$OUT")" = "$before" ] && [ ! -e "$REC/pg_dump.log" ] && ok "dry-run: no check, nothing written" || nok "dry-run changed state (rc=$rc): $(ls "$OUT")"

exit $FAIL
