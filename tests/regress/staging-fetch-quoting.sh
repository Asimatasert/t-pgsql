#!/usr/bin/env bash
# Regression: `fetch --from-file` must be quoted for the remote shell and must
# reject values containing '/' or starting with '-'. Run from the repo root:
#   bash tests/regress/staging-fetch-quoting.sh   (T_PGSQL_BIN overrides ./t-pgsql)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${T_PGSQL_BIN:-$ROOT/t-pgsql}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0
ok()  { echo "ok - $1"; }
nok() { echo "not ok - $1"; FAIL=1; }

SB="$TMP/sandbox"; FAKE="$TMP/fake"; REC="$TMP/rec"
mkdir -p "$SB/t-pgsql" "$FAKE" "$REC" "$TMP/out"
chmod 700 "$SB/t-pgsql"
printf 'PGDMP-fake\n' > "$SB/t-pgsql/appdb_20200101_000000.dump"
printf 'PGDMP-fake\n' > "$SB/outside.dump"

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
src="${src#*@*:}"
src="${src//\/tmp\/t-pgsql/$SB/t-pgsql}"
cp "$src" "$dst"
EOF
for t in psql pg_restore pg_dump pg_isready createdb dropdb pg_dumpall; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE/$t"
done
chmod +x "$FAKE"/*
export SB REC
export PATH="$FAKE:$PATH"
export T_PGSQL_FROM_PASSWORD=x
export HOME="$TMP/home"; mkdir -p "$HOME"
SRC="ssh://u@192.0.2.1/postgres@localhost/appdb"
fetch() { "$BIN" fetch --from "$SRC" --output "$TMP/out" --from-file "$1" </dev/null 2>&1; }

# 1. glob with shell metacharacters must not execute anything remotely
out=$(fetch "appdb*; touch $SB/PWNED #")
[ ! -e "$SB/PWNED" ] && ok "metacharacters in --from-file are not executed" || nok "remote command injection through --from-file"

# 2. quote characters stay literal
out=$(fetch "appdb*'; touch $SB/PWNED2; echo '")
[ ! -e "$SB/PWNED2" ] && ok "quotes in --from-file stay literal" || nok "quote breakout through --from-file"

# 3. slash and leading dash rejected
rm -f "$REC/scp.log"
out=$(fetch "../outside.dump"); rc=$?
[ ! -s "$REC/scp.log" ] && ok "value with '/' is rejected (no download)" || nok "value with '/' was downloaded"
out=$(fetch "/etc/hostname")
[ ! -s "$REC/scp.log" ] && ok "absolute path is rejected" || nok "absolute path was downloaded"
out=$(fetch "../outside.dump")
case "$out" in *"--from-file"*) ok "clear error for rejected value" ;; *) nok "no clear error: $out" ;; esac

# 4. valid exact name and glob still work
rm -f "$REC/scp.log"
out=$(fetch "appdb_20200101_000000.dump")
grep -q "appdb_20200101_000000.dump" "$REC/scp.log" 2>/dev/null && ok "exact file name still fetched" || nok "exact name not fetched: $out"
rm -f "$REC/scp.log"
out=$(fetch "appdb_2020*.dump")
grep -q "appdb_20200101_000000.dump" "$REC/scp.log" 2>/dev/null && ok "glob still fetched" || nok "glob not fetched: $out"

exit $FAIL
