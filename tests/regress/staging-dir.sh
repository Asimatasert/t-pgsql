#!/usr/bin/env bash
# Regression: the remote staging directory must be verified (real directory,
# owned by the connecting user, no group/other permissions) before dump,
# restore or fetch use it over ssh. Run from the repo root:
#   bash tests/regress/staging-dir.sh        (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

SB="$TMP/sandbox"; FAKE="$TMP/fake"; REC="$TMP/rec"
mkdir -p "$SB" "$FAKE" "$REC" "$TMP/out"

# Fake ssh: run the remote command locally; /tmp/t-pgsql is redirected into
# the sandbox. The script on stdin (ssh_exec) is rewritten the same way.
cat > "$FAKE/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
echo "$cmd" >> "$REC/ssh.log"
cmd="${cmd//\/tmp\/t-pgsql/$SB/t-pgsql}"
sed "s#/tmp/t-pgsql#$SB/t-pgsql#g" | sh -c "$cmd"
EOF
cat > "$FAKE/scp" <<'EOF'
#!/usr/bin/env bash
a=("$@"); src="${a[$((${#a[@]}-2))]}"; dst="${a[$((${#a[@]}-1))]}"
echo "scp $src $dst" >> "$REC/scp.log"
src="${src#*@*:}"; dst="${dst#*@*:}"
src="${src//\/tmp\/t-pgsql/$SB/t-pgsql}"; dst="${dst//\/tmp\/t-pgsql/$SB/t-pgsql}"
cp "$src" "$dst"
EOF
cat > "$FAKE/pg_dump" <<'EOF'
#!/usr/bin/env bash
echo "pg_dump $*" >> "$REC/pg_dump.log"
while [ $# -gt 0 ]; do [ "$1" = -f ] && { printf 'PGDMP-fake\n' > "$2"; }; shift; done
exit 0
EOF
cat > "$FAKE/pg_restore" <<'EOF'
#!/usr/bin/env bash
echo "pg_restore $*" >> "$REC/pg_restore.log"; exit 0
EOF
cat > "$FAKE/psql" <<'EOF'
#!/usr/bin/env bash
echo "psql $*" >> "$REC/psql.log"; exit 0
EOF
for t in pg_isready createdb dropdb pg_dumpall; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
chmod +x "$FAKE"/*
export SB REC
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x T_PGSQL_TO_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"

run_dump()  { "$BIN" dump --from "ssh://u@192.0.2.1/postgres@localhost/appdb" --output "$TMP/out" --from-keep 1 --min-size-ratio 0 </dev/null 2>&1; }
reset()     { rm -rf "$SB/t-pgsql" "$SB/evil" "$FAKE/id" "$FAKE/chmod" "$REC"/*; }

# --- 1. clean host: operation proceeds and the directory is 700 --------------
reset
out=$(run_dump); rc=$?
mode=$(ls -ld "$SB/t-pgsql" | cut -c1-10)
[ $rc -eq 0 ] && ok "dump succeeds with a fresh staging dir" || { nok "dump failed rc=$rc: $out"; }
[ "$mode" = "drwx------" ] && ok "staging dir is mode 700" || nok "staging dir mode is $mode"

# --- 2. symlink planted by another account -----------------------------------
reset; mkdir "$SB/evil"; chmod 755 "$SB/evil"; ln -s "$SB/evil" "$SB/t-pgsql"
out=$(run_dump); rc=$?
[ $rc -ne 0 ] && ok "dump aborts when staging dir is a symlink" || nok "dump continued through a symlink"
[ -z "$(ls -A "$SB/evil")" ] && ok "nothing written through the symlink" || nok "files landed in the symlink target"
[ "$(ls -ld "$SB/evil" | cut -c1-10)" = "drwxr-xr-x" ] && ok "chmod never followed the symlink" || nok "symlink target mode was changed"
[ ! -s "$REC/pg_dump.log" ] && ok "pg_dump never ran" || nok "pg_dump ran against an unsafe dir"
case "$out" in *"unsafe"*) ok "clear error message" ;; *) nok "no clear error: $out" ;; esac

# --- 3. directory owned by someone else (remote id -u differs) ---------------
reset; mkdir "$SB/t-pgsql"; chmod 755 "$SB/t-pgsql"
printf '#!/bin/sh\necho 99999\n' > "$FAKE/id"; chmod +x "$FAKE/id"
out=$(run_dump); rc=$?
[ $rc -ne 0 ] && ok "dump aborts when the directory owner differs" || nok "dump continued with foreign owner"
[ ! -s "$REC/pg_dump.log" ] && ok "pg_dump never ran (owner)" || nok "pg_dump ran (owner)"
[ "$(ls -ld "$SB/t-pgsql" | cut -c1-10)" = "drwxr-xr-x" ] && ok "foreign-owned directory is not chmod'ed" || nok "mode changed before the owner check"
rm -f "$FAKE/id"

# --- 4. directory stays group/other accessible (chmod cannot fix it) ---------
reset; mkdir "$SB/t-pgsql"; chmod 755 "$SB/t-pgsql"
printf '#!/bin/sh\nexit 1\n' > "$FAKE/chmod"; chmod +x "$FAKE/chmod"
out=$(run_dump); rc=$?
[ $rc -ne 0 ] && ok "dump aborts on group/other permissions" || nok "dump continued with mode 755"
rm -f "$FAKE/chmod"

# --- 5. pre-existing loose directory owned by the user is tightened ----------
reset; mkdir "$SB/t-pgsql"; chmod 755 "$SB/t-pgsql"
out=$(run_dump); rc=$?
[ $rc -eq 0 ] && ok "own 755 directory is tightened to 700 and used" || nok "own 755 dir rejected: $out"

# --- 6. restore --to ssh:// refuses a symlinked staging dir ------------------
reset; mkdir "$SB/evil"; ln -s "$SB/evil" "$SB/t-pgsql"
printf 'PGDMP-fake\n' > "$TMP/in_20260101_000000.dump"
out=$("$BIN" restore --file "$TMP/in_20260101_000000.dump" --to "ssh://u@192.0.2.1/postgres@localhost/appdb" </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && ok "restore aborts on unsafe staging dir" || nok "restore continued: $out"
[ ! -s "$REC/scp.log" ] && ok "restore did not upload" || nok "restore uploaded into unsafe dir"

# --- 7. fetch refuses a symlinked staging dir --------------------------------
reset; mkdir "$SB/evil"; ln -s "$SB/evil" "$SB/t-pgsql"
out=$("$BIN" fetch --from "ssh://u@192.0.2.1/postgres@localhost/appdb" --output "$TMP/out" </dev/null 2>&1); rc=$?
[ $rc -ne 0 ] && ok "fetch aborts on unsafe staging dir" || nok "fetch continued: $out"
case "$out" in *"unsafe"*) ok "fetch reports the unsafe directory" ;; *) nok "fetch gave no clear error: $out" ;; esac

exit $FAIL
